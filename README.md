# 팀플 회의시간 자동합의 서비스 — V3

선호도 기반 최적시간 자동추천 프로토타입. 「팀플 회의시간 자동합의 서비스 MVP」 최종보고서의
V1(가능시간 선택형) → V2(불가능시간 제외형) → **V3(선호도 기반 최적시간 자동추천)** 중 세 번째 사이클에 해당한다.

## 실행

`index.html` 하나로 끝난다. 빌드 과정이 없다.

```bash
open index.html
```

## 두 가지 저장 모드

화면 오른쪽 위 배지가 지금 어느 모드인지 알려준다.

| 배지 | 저장 위치 | 쓰는 상황 |
|---|---|---|
| ● 팀 공유 | Supabase | 팀원이 각자 기기에서 회의 코드로 참여 |
| ○ 이 브라우저 | localStorage | 서버에 못 닿을 때 자동 전환 |

브라우저는 시작할 때 설정을 이 순서로 찾는다.

1. `window.V3_CONFIG = {url, key}` — 로컬에서 잠깐 시험할 때 쓰는 탈출구
2. `GET /api/config` — Vercel 환경변수에서 읽어 내려주는 값
3. 둘 다 없거나 서버에 닿지 못하면 브라우저 저장 모드

즉 `index.html` 에는 프로젝트 주소도 키도 들어 있지 않다. GitHub Pages나 파일을 직접 열면
`/api/config` 가 없으니 브라우저 저장 모드로 돈다. 화면과 기능은 양쪽이 같다.

## 배포 (Vercel)

1. https://vercel.com 에서 이 저장소를 Import
2. **Settings → Environment Variables** 에 두 개를 추가 (Production·Preview·Development 모두 체크)
   - 주소: `SUPABASE_URL` (또는 `SUPABASE_PROJECT_URL`) — 예: `https://xxxxxxxx.supabase.co`
   - 키: `SUPABASE_ANON_KEY` (또는 `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_KEY`) — 아래 표 참고
3. Deploy. 환경변수를 나중에 바꾸면 재배포해야 반영된다.

Framework Preset은 `Other`, Build Command와 Output Directory는 비워둔다. 빌드가 없는
정적 HTML + `api/` 함수 조합이다.

### 어떤 키를 넣는가

Supabase의 **Project Settings → API Keys** 는 페이지 이름이고, 그 안에 여러 키가 있다.
Supabase가 `anon` 키를 `Publishable` 로 이름만 바꿨으므로 아래 둘 중 어느 것이든 된다.

| 화면 표시 | DB 역할 | 브라우저 |
|---|---|---|
| `Publishable key` — `sb_publishable_…` | `anon` | 넣어도 됨 |
| Legacy API keys 탭의 `anon` `public` — `eyJ…` | `anon` | 넣어도 됨 |
| `Secret keys` — `sb_secret_…` | service_role 대체 | **절대 안 됨** |
| Legacy API keys 탭의 `service_role` — `eyJ…` | `service_role` | **절대 안 됨** |

레거시 키는 `anon` 과 `service_role` 이 둘 다 `eyJ…` 로 시작해 겉모습으로 구분되지 않는다.
넣은 키가 안전한지는 테이블 직접 읽기로 판정한다.

```bash
KEY='...' && curl -s "$SUPABASE_URL/rest/v1/meetings?select=code" -H "apikey: $KEY"
```

`[]` 가 나오면 RLS가 막고 있는 안전한 키다. 행이 나오면 RLS를 우회하는 키이므로 즉시
Supabase에서 폐기하고 publishable 키로 바꾼다.

[api/config.js](api/config.js) 가 이 값을 읽어 브라우저에 내려준다. 정적 HTML은 환경변수를
런타임에 직접 읽을 수 없어 이 함수 한 개를 둔다.

## Supabase

[supabase/schema.sql](supabase/schema.sql) 을 SQL Editor에 붙여넣어 실행하면 끝난다.
테이블은 RLS로 직접 접근을 막고 `security definer` 함수만 anon에 열어두었다.
비밀번호는 브라우저에서 해시로 바꿔 보내므로 평문이 서버에 남지 않고, 조회 응답에도
해시가 포함되지 않는다.

publishable(anon) 키는 원래 브라우저에 노출되는 값이다. 환경변수로 옮긴 목적은 키를
비밀로 만드는 것이 아니라 저장소에서 떼어내 프로젝트 교체·키 교체 때 코드를 고치지 않게
하는 것이다. 실제 데이터 보호는 RLS와 함수 권한이 담당한다.

## 화면 흐름

첫 화면에서 **회의 생성하기 / 회의 참여하기** 중 하나를 고른다.

### 팀장 — 회의 생성
- 회의 이름, 팀 인원
- 달력에서 날짜 다중 선택 (최대 7일)
- 시간 범위 0시~24시, 1시간 단위 슬롯
- 팀장 비밀번호(선택) — 걸어두면 팀장 화면을 열 때 비밀번호를 확인한다
- 생성하면 6자리 **회의 코드**가 발급된다

### 팀원 — 회의 참여
- 회의 코드 + 이름, 개인 비밀번호(선택)
- 3상태 시간표: 기본값 **가능**, 안 되는 칸은 **불가능**, 특히 좋은 칸은 **⭐선호**
- 같은 이름으로 다시 들어오면 자기 응답을 수정할 수 있다.
  개인 비밀번호를 정해두면 그 이름은 본인만 열 수 있다

### 팀장 — 추천과 확정
- 회의 정보와 응답 현황(응답률, 선호 표시 수, 응답자 목록)
- 추천 후보 3개와 근거 표시: `8/18(화) 19:00–20:00 · 5/5 참석 가능 · ⭐4명 선호`
- 확정 회의시간을 **1·2·3순위**로 지정. 1순위는 실제 회의시간, 2·3순위는 예비
- 전체 시간표 히트맵(숫자=참석 가능 인원, ★=선호 수)에서 직접 고를 수도 있다.
  칸을 누르면 그 시간에 선호·가능·불가능을 고른 팀원 이름이 보인다
- 확정 후에도 회의 정보는 남고, 확정 순위를 다시 바꿀 수 있다
- 회의 삭제는 팀장 화면 맨 아래에서만 가능하고, 회의 코드를 입력해야 실행된다

## 추천 우선순위 (보고서 10.1)

1. 참석 가능 인원이 많은 슬롯
2. 선호 표시 수가 많은 슬롯
3. 더 이른 날짜·시간

점수화는 `선호 2점 / 가능 1점 / 불가능 제외`를 초기 설계값으로 둔다. 사용자 검증 전의 가설이며 정답이 아니다.

## 행동로그 (보고서 5.2)

`schedule_create`, `share_click`, `member_open`, `member_input_start`, `member_submit`,
`member_edit_open`, `member_revise`, `recommend_view`, `final_confirm`, `override_recommend`,
`pin_required`, `pin_fail`, `leader_gate`, `leader_gate_fail`, `response_delete`

입력 소요시간과 조작 횟수까지 함께 기록되고, 팀장 화면에서 **CSV로 내보내기**가 된다.
가드레일 지표인 제출 후 수정률은 `member_revise ÷ member_submit`으로 계산한다.

팀 공유 모드에서는 로그가 `events` 테이블에 모이므로 **모든 팀원 기기의 행동이 한 CSV로 나온다.**
브라우저 저장 모드에서는 그 기기의 로그만 나온다.

## 권한

- 팀장 화면은 회의를 만든 기기에서 바로 열린다. 다른 기기에서는 첫 화면의
  `다른 기기에서 팀장 화면 열기` 에 회의 코드와 팀장 비밀번호를 넣어 열 수 있다.
- 회의 코드만 아는 사람은 참여 화면과 확정 결과만 볼 수 있다. 팀장 비밀번호가 걸린 회의는
  서버가 팀원별 응답 상세를 아예 내려주지 않는다.
- 팀장 비밀번호를 정하지 않은 회의는 코드를 아는 사람이면 팀장 화면을 열 수 있다.

## 제약

- 비밀번호는 실수로 서로의 응답을 덮어쓰는 것을 막는 **잠금**이며 암호학적 보안은 아니다.
  해시가 약한 함수이고, 회의 코드는 6자리다.
- 브라우저 저장 모드에서 팀원이 각자 기기로 입력한 경우, 제출 화면의 **응답 코드**(`R1.…`)를
  팀장에게 보내면 팀장 화면의 `응답 코드 입력` 으로 합칠 수 있다.
- 삭제한 회의는 되돌릴 수 없다.
