-- 팀플 회의시간 자동합의 V3 — Supabase 스키마
-- Supabase 대시보드 → SQL Editor 에 이 파일 전체를 붙여넣고 Run 하면 된다.
-- 여러 번 실행해도 안전하다.

-- ---------------------------------------------------------------- 테이블

create table if not exists public.meetings (
  code        text primary key,
  title       text not null,
  team_size   int  not null default 5,
  dates       jsonb not null,               -- ["2026-08-18", ...]
  h_start     int  not null,
  h_end       int  not null,
  leader_pin  text,                         -- 팀장 비밀번호 해시 (평문 아님)
  confirmed   jsonb,                        -- {ts, fromTop, picks:[{d,h}]}
  created_at  timestamptz not null default now()
);

create table if not exists public.responses (
  meeting_code text not null references public.meetings(code) on delete cascade,
  name         text not null,
  pin          text,                        -- 개인 비밀번호 해시 (평문 아님)
  slots        jsonb not null,              -- {"0-18":"no","1-19":"prefer", ...}
  updated_at   timestamptz not null default now(),
  primary key (meeting_code, name)
);

create table if not exists public.events (
  id           bigserial primary key,
  meeting_code text,
  event        text not null,
  actor        text,
  meta         text,
  created_at   timestamptz not null default now()
);

create index if not exists events_code_idx on public.events (meeting_code, created_at);

-- ---------------------------------------------------------------- 접근 차단
-- RLS를 켜고 정책을 하나도 두지 않아 테이블 직접 접근을 전부 막는다.
-- 모든 읽기/쓰기는 아래 security definer 함수만 통과한다.

alter table public.meetings  enable row level security;
alter table public.responses enable row level security;
alter table public.events    enable row level security;

-- ---------------------------------------------------------------- 회의 생성

create or replace function public.create_meeting(
  p_title text, p_team_size int, p_dates jsonb,
  p_h_start int, p_h_end int, p_leader_pin text
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  i int;
begin
  if p_h_end <= p_h_start then
    raise exception 'invalid_hours';
  end if;
  if jsonb_array_length(p_dates) < 1 or jsonb_array_length(p_dates) > 7 then
    raise exception 'invalid_dates';
  end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    exit when not exists (select 1 from meetings where code = v_code);
  end loop;

  insert into meetings (code, title, team_size, dates, h_start, h_end, leader_pin)
  values (v_code, left(coalesce(nullif(p_title,''), '팀플 회의'), 60),
          greatest(2, least(20, coalesce(p_team_size, 5))),
          p_dates, p_h_start, p_h_end, nullif(p_leader_pin, ''));

  return v_code;
end $$;

-- ---------------------------------------------------------------- 조회
-- 항상: 회의 기본정보, 응답자 이름과 잠금 여부, 확정 결과
-- p_name + p_pin 이 맞으면: 그 사람의 이전 응답(myResponse)
-- 팀장 조건을 만족하면: 전체 응답(responses) — 히트맵·추천 계산용
--   (팀장 비밀번호가 없는 회의는 코드를 아는 사람이면 전체를 볼 수 있다)

create or replace function public.get_meeting(
  p_code text, p_name text default null,
  p_pin text default null, p_leader_pin text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m           meetings;
  v_is_leader boolean;
  v_names     jsonb;
  v_all       jsonb;
  v_mine      jsonb;
begin
  select * into m from meetings where code = upper(p_code);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_meeting');
  end if;

  v_is_leader := m.leader_pin is null
                 or (p_leader_pin is not null and p_leader_pin = m.leader_pin);

  select coalesce(jsonb_agg(jsonb_build_object('name', name, 'locked', pin is not null)
                            order by updated_at), '[]'::jsonb)
    into v_names from responses where meeting_code = m.code;

  if v_is_leader then
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'slots', slots,
                                                 'locked', pin is not null)
                              order by updated_at), '[]'::jsonb)
      into v_all from responses where meeting_code = m.code;
  else
    v_all := null;
  end if;

  if p_name is not null and p_name <> '' then
    select jsonb_build_object('name', name, 'slots', slots, 'locked', pin is not null)
      into v_mine from responses
     where meeting_code = m.code and name = p_name
       and (pin is null or pin = p_pin);
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', m.code, 'title', m.title, 'size', m.team_size, 'dates', m.dates,
    'hStart', m.h_start, 'hEnd', m.h_end, 'createdAt', m.created_at,
    'leaderLocked', m.leader_pin is not null,
    'isLeader', v_is_leader,
    'confirmed', m.confirmed,
    'people', v_names,
    'responses', v_all,
    'myResponse', v_mine
  );
end $$;

-- ---------------------------------------------------------------- 이름 잠금 확인
-- 'new' 처음 | 'open' 잠금 없음 | 'pin_required' 비번 필요 | 'pin_fail' 불일치 | 'ok' 통과

create or replace function public.check_response_pin(
  p_code text, p_name text, p_pin text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text;
begin
  if not exists (select 1 from meetings where code = upper(p_code)) then
    return 'no_meeting';
  end if;
  select pin into v_pin from responses
   where meeting_code = upper(p_code) and name = p_name;
  if not found then return 'new'; end if;
  if v_pin is null then return 'open'; end if;
  if p_pin is null or p_pin = '' then return 'pin_required'; end if;
  if p_pin <> v_pin then return 'pin_fail'; end if;
  return 'ok';
end $$;

-- ---------------------------------------------------------------- 응답 저장

create or replace function public.upsert_response(
  p_code text, p_name text, p_pin text, p_slots jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text; v_had boolean := false;
begin
  if not exists (select 1 from meetings where code = upper(p_code)) then
    return 'no_meeting';
  end if;
  if p_name is null or btrim(p_name) = '' then
    return 'no_name';
  end if;

  select pin into v_pin from responses
   where meeting_code = upper(p_code) and name = p_name;
  v_had := found;

  -- 잠긴 이름은 비밀번호가 맞아야 덮어쓸 수 있다.
  if v_had and v_pin is not null and (p_pin is null or p_pin <> v_pin) then
    return 'pin_fail';
  end if;

  insert into responses (meeting_code, name, pin, slots, updated_at)
  values (upper(p_code), btrim(p_name), coalesce(nullif(p_pin, ''), v_pin), p_slots, now())
  on conflict (meeting_code, name) do update
    set slots = excluded.slots, pin = excluded.pin, updated_at = now();

  return case when v_had then 'updated' else 'created' end;
end $$;

-- ---------------------------------------------------------------- 팀장 확인

create or replace function public.check_leader(p_code text, p_leader_pin text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text;
begin
  select leader_pin into v_pin from meetings where code = upper(p_code);
  if not found then return 'no_meeting'; end if;
  if v_pin is null then return 'open'; end if;
  if p_leader_pin is null or p_leader_pin = '' then return 'pin_required'; end if;
  if p_leader_pin <> v_pin then return 'pin_fail'; end if;
  return 'ok';
end $$;

-- ---------------------------------------------------------------- 확정 저장

create or replace function public.set_confirmed(
  p_code text, p_leader_pin text, p_confirmed jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text;
begin
  select leader_pin into v_pin from meetings where code = upper(p_code);
  if not found then return 'no_meeting'; end if;
  if v_pin is not null and (p_leader_pin is null or p_leader_pin <> v_pin) then
    return 'pin_fail';
  end if;
  update meetings set confirmed = p_confirmed where code = upper(p_code);
  return 'ok';
end $$;

-- ---------------------------------------------------------------- 삭제

create or replace function public.delete_response(
  p_code text, p_leader_pin text, p_name text
) returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text;
begin
  select leader_pin into v_pin from meetings where code = upper(p_code);
  if not found then return 'no_meeting'; end if;
  if v_pin is not null and (p_leader_pin is null or p_leader_pin <> v_pin) then
    return 'pin_fail';
  end if;
  delete from responses where meeting_code = upper(p_code) and name = p_name;
  return 'ok';
end $$;

create or replace function public.delete_meeting(p_code text, p_leader_pin text)
returns text
language plpgsql security definer set search_path = public as $$
declare v_pin text;
begin
  select leader_pin into v_pin from meetings where code = upper(p_code);
  if not found then return 'no_meeting'; end if;
  if v_pin is not null and (p_leader_pin is null or p_leader_pin <> v_pin) then
    return 'pin_fail';
  end if;
  delete from meetings where code = upper(p_code);   -- 응답은 cascade
  return 'ok';
end $$;

-- ---------------------------------------------------------------- 행동로그

create or replace function public.log_event(
  p_code text, p_event text, p_actor text default null, p_meta text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into events (meeting_code, event, actor, meta)
  values (nullif(upper(coalesce(p_code,'')), ''), left(p_event, 40),
          left(coalesce(p_actor,''), 40), left(coalesce(p_meta,''), 200));
end $$;

-- 팀장이 CSV로 내려받을 로그 (해당 회의 것만)
create or replace function public.get_events(p_code text, p_leader_pin text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_pin text; v_rows jsonb;
begin
  select leader_pin into v_pin from meetings where code = upper(p_code);
  if not found then return jsonb_build_object('ok', false, 'error', 'no_meeting'); end if;
  if v_pin is not null and (p_leader_pin is null or p_leader_pin <> v_pin) then
    return jsonb_build_object('ok', false, 'error', 'pin_fail');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'iso', created_at, 'event', event, 'actor', actor, 'meta', meta
         ) order by created_at), '[]'::jsonb)
    into v_rows from events where meeting_code = upper(p_code);
  return jsonb_build_object('ok', true, 'rows', v_rows);
end $$;

-- ---------------------------------------------------------------- 실행 권한
-- 브라우저(anon)는 아래 함수만 호출할 수 있다.

revoke all on function
  public.create_meeting(text,int,jsonb,int,int,text),
  public.get_meeting(text,text,text,text),
  public.check_response_pin(text,text,text),
  public.upsert_response(text,text,text,jsonb),
  public.check_leader(text,text),
  public.set_confirmed(text,text,jsonb),
  public.delete_response(text,text,text),
  public.delete_meeting(text,text),
  public.log_event(text,text,text,text),
  public.get_events(text,text)
from public;

grant execute on function
  public.create_meeting(text,int,jsonb,int,int,text),
  public.get_meeting(text,text,text,text),
  public.check_response_pin(text,text,text),
  public.upsert_response(text,text,text,jsonb),
  public.check_leader(text,text),
  public.set_confirmed(text,text,jsonb),
  public.delete_response(text,text,text),
  public.delete_meeting(text,text),
  public.log_event(text,text,text,text),
  public.get_events(text,text)
to anon, authenticated;
