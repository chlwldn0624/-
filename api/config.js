// Vercel 서버리스 함수. 브라우저가 시작할 때 이 주소로 Supabase 설정을 받아간다.
// 값은 저장소에 두지 않고 Vercel 환경변수(SUPABASE_URL, SUPABASE_ANON_KEY)에서 읽는다.
//
// 여기서 내려주는 publishable(anon) 키는 원래 브라우저에 노출되는 값이다.
// 환경변수로 옮긴 목적은 "비밀로 만드는 것"이 아니라, 저장소에서 키를 떼어내
// 프로젝트를 바꾸거나 키를 교체할 때 코드를 고치지 않아도 되게 하는 것이다.
// 실제 데이터 보호는 RLS + security definer 함수(supabase/schema.sql)가 담당한다.

// 키 환경변수는 아래 이름 중 아무거나 쓰면 된다. Supabase가 anon 키를
// publishable 키로 이름을 바꿨기 때문에 어느 쪽으로 적어도 동작하게 둔다.
//   SUPABASE_ANON_KEY | SUPABASE_PUBLISHABLE_KEY | SUPABASE_KEY
const KEY_VARS = ["SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEY", "SUPABASE_KEY"];
const URL_VARS = ["SUPABASE_URL", "SUPABASE_PROJECT_URL"];

function pick(names) {
  for (const n of names) {
    const v = (process.env[n] || "").trim();
    if (v) return v;
  }
  return "";
}

module.exports = function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.status(200).end(JSON.stringify({
    url: pick(URL_VARS),
    key: pick(KEY_VARS)
  }));
};
