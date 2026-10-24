// اختبار حمل 3.5 — يُشغَّل على مشروع Supabase تجريبي فقط.
// التشغيل المحلي (تجربة صغيرة):   k6 run -e URL=https://xxx.supabase.co -e ANON=eyJ... -e PROFILE=smoke k6_load.js
// الأحمال: PROFILE = smoke (50) | p2 (10,000) | p3 (50,000)
// 50,000 مستخدم متزامن لا تتحمله آلة واحدة: وزّع على عدة آلات بـ --execution-segment أو استعمل Grafana Cloud k6.
//   مثال آلة 2 من 5:  k6 run --execution-segment "1/5:2/5" --execution-segment-sequence "0,1/5,2/5,3/5,4/5,1" ...
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import exec from 'k6/execution';

const URL = __ENV.URL, ANON = __ENV.ANON, PW = __ENV.PW || 'LoadTest#2026';
const N_STUDENTS = +(__ENV.N_STUDENTS || 50000), TEACHER_SHARE = 0.04;   // 4% معلمون ≈ طالب لكل 25
const PROFILES = {
  smoke: [{ duration: '30s', target: 50 }, { duration: '1m', target: 50 }, { duration: '15s', target: 0 }],
  p2:    [{ duration: '5m', target: 2500 }, { duration: '5m', target: 5000 }, { duration: '5m', target: 10000 }, { duration: '10m', target: 10000 }, { duration: '3m', target: 0 }],
  p3:    [{ duration: '10m', target: 10000 }, { duration: '10m', target: 25000 }, { duration: '10m', target: 50000 }, { duration: '15m', target: 50000 }, { duration: '5m', target: 0 }],
};
export const options = {
  scenarios: { users: { executor: 'ramping-vus', startVUs: 0, stages: PROFILES[__ENV.PROFILE || 'smoke'], gracefulRampDown: '1m' } },
  thresholds: {
    'http_req_failed': ['rate<0.01'],
    'open_app_ms': ['p(95)<2000'],        // فتح التطبيق (دخول + تحميل البيانات)
    'save_session_ms': ['p(95)<500'],     // KPI: حفظ حصة < 500 مللي ثانية
    'points_ms': ['p(95)<800'],
    'login_ms': ['p(95)<1500'],
    'errors': ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};
const openApp = new Trend('open_app_ms', true), saveT = new Trend('save_session_ms', true), pointsT = new Trend('points_ms', true),
      loginT = new Trend('login_ms', true), errors = new Rate('errors'), saves = new Counter('sessions_saved');

const H = (tok) => ({ apikey: ANON, Authorization: 'Bearer ' + (tok || ANON), 'Content-Type': 'application/json' });
function rpc(name, body, tok, tag) { return http.post(`${URL}/rest/v1/rpc/${name}`, JSON.stringify(body), { headers: H(tok), tags: { name: tag || name } }); }
function login(email) {
  const r = http.post(`${URL}/auth/v1/token?grant_type=password`, JSON.stringify({ email, password: PW }), { headers: H(), tags: { name: 'login' } });
  loginT.add(r.timings.duration);
  const ok = check(r, { 'login 200': (x) => x.status === 200 }); errors.add(!ok);
  return ok ? r.json('access_token') : null;
}
const rnd = (n) => 1 + Math.floor(Math.random() * n);
const today = () => new Date().toISOString().slice(0, 10);

export default function () {
  const isTeacher = Math.random() < TEACHER_SHARE;
  const nT = Math.ceil(N_STUDENTS / 25);
  const id = isTeacher ? rnd(nT) : rnd(N_STUDENTS);
  const tok = login(isTeacher ? `tch${id}@load.test` : `stu${id}@load.test`);
  if (!tok) { sleep(5); return; }

  // ---- فتح التطبيق: ما يفعله index.html (تفعيل النقاط من الخادم + تحميل الوثائق المسموحة) ----
  const t0 = Date.now();
  const en = rpc('points_server_enabled', {}, tok);
  const docs = http.get(`${URL}/rest/v1/docs?select=col,id,data,updated_at&col=in.(students,enrollments,halaqat,teachers,settings)&order=col,id&limit=1000`,
    { headers: H(tok), tags: { name: 'load_docs' } });
  openApp.add(Date.now() - t0);
  errors.add(!check(docs, { 'docs 200': (r) => r.status === 200 }) || en.status !== 200);

  if (isTeacher) {
    // ---- معلم: يحفظ حصة لحلقته (25 طالباً) ثم يستعرض النقاط ----
    const first = (id - 1) * 25 + 1, marks = {}, prog = {};
    const sess = `load_${exec.vu.idInTest}_${Date.now()}`;
    for (let i = 0; i < 25; i++) {
      const sid = 's' + (first + i); if (first + i > N_STUDENTS) break;
      marks[sid] = ['p', 'p', 'p', 'l', 'a'][rnd(5) - 1];
      prog[sid] = { rec: [{ id: sess + sid, d: today(), g: ['good', 'vgood', 'excellent'][rnd(3) - 1], sessionId: sess }], rash: [] };
    }
    sleep(rnd(3));
    const s = rpc('save_session', { p_session_id: sess, p_session: { date: today(), teacherId: 't' + id, status: 'تمت' }, p_date: today(), p_marks: marks, p_prog: prog, p_homework: {} }, tok);
    saveT.add(s.timings.duration); saves.add(1);
    errors.add(!check(s, { 'save ok': (r) => r.status === 200 && r.json('ok') === true }));
    const p = rpc('points_many', { p_sids: Object.keys(marks) }, tok); pointsT.add(p.timings.duration);
    errors.add(!check(p, { 'points ok': (r) => r.status === 200 }));
  } else {
    // ---- طالب: نقاطي + ترتيبي في الحلقة ----
    sleep(rnd(3));
    const p = rpc('points_many', { p_sids: ['s' + id] }, tok); pointsT.add(p.timings.duration);
    const r = rpc('halaqa_rank', { p_sid: 's' + id }, tok); pointsT.add(r.timings.duration);
    errors.add(!check(p, { 'points 200': (x) => x.status === 200 }) || !check(r, { 'rank 200': (x) => x.status === 200 }));
  }
  sleep(10 + Math.random() * 20);   // زمن تفكير المستخدم قبل الدورة التالية
}
