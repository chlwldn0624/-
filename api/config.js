// Vercel 서버리스 함수. 브라우저가 시작할 때 이 주소로 Supabase 설정을 받아간다.
// 값은 저장소에 두지 않고 Vercel 환경변수(SUPABASE_URL, SUPABASE_ANON_KEY)에서 읽는다.
//
// 여기서 내려주는 publishable(anon) 키는 원래 브라우저에 노출되는 값이다.
// 환경변수로 옮긴 목적은 "비밀로 만드는 것"이 아니라, 저장소에서 키를 떼어내
// 프로젝트를 바꾸거나 키를 교체할 때 코드를 고치지 않아도 되게 하는 것이다.
// 실제 데이터 보호는 RLS + security definer 함수(supabase/schema.sql)가 담당한다.

module.exports = function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.status(200).end(JSON.stringify({
    url: process.env.SUPABASE_URL || "",
    key: process.env.SUPABASE_ANON_KEY || ""
  }));
};
