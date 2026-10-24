-- اختبارات SQL لـ: حفظ الحصة الذرّي، النقاط، أمان RLS، الأرشفة.  أي فشل = خطأ يوقف الملف.
-- شغّل على قاعدة تجريبية فيها 01 و02 و03.   psql -v ON_ERROR_STOP=1 -f rls_and_session.sql
\set ON_ERROR_STOP on
begin;
delete from docs; delete from profiles; delete from auth.users; delete from docs_archive; delete from app_config where key='points_server';
insert into auth.users values
 ('00000000-0000-0000-0000-00000000000a','gm@x'),('00000000-0000-0000-0000-00000000000b','u-5@x'),
 ('00000000-0000-0000-0000-00000000000c','u-100@x'),('00000000-0000-0000-0000-00000000000d','u-101@x'),
 ('00000000-0000-0000-0000-00000000000e','u-6@x'),('00000000-0000-0000-0000-00000000000f','u-77@x');
insert into profiles(id,email,role,teacher_id,center_id,student_id) values
 ('00000000-0000-0000-0000-00000000000a','gm@x','gm',null,null,null),
 ('00000000-0000-0000-0000-00000000000b','u-5@x','teacher','t1','c1',null),
 ('00000000-0000-0000-0000-00000000000c','u-100@x','student',null,null,'s0'),
 ('00000000-0000-0000-0000-00000000000d','u-101@x','student',null,null,'s1'),
 ('00000000-0000-0000-0000-00000000000e','u-6@x','teacher','t2','c2',null),
 ('00000000-0000-0000-0000-00000000000f','u-77@x','student',null,null,'s77');
insert into docs(col,id,data) values
 ('settings','main','{"currentYear":"2026"}'),
 ('centers','c1','{"regionId":"r1"}'),('centers','c2','{"regionId":"r1"}'),
 ('teachers','t1','{"centerId":"c1","self_no":"5"}'),('teachers','t2','{"centerId":"c2","self_no":"6"}'),
 ('students','s0','{"name":"أحمد","no":"100","self_no":"100"}'),('students','s1','{"name":"بكر","no":"101","self_no":"101"}'),
 ('students','s9','{"name":"عمر","no":"109"}'),
 ('halaqat','h1','{"centerId":"c1","teacherId":"t1"}'),('halaqat','h2','{"centerId":"c2","teacherId":"t2"}'),
 ('enrollments','e0','{"studentId":"s0","centerId":"c1","teacherId":"t1","halaqaId":"h1","year":"2026","status":"نشط"}'),
 ('enrollments','e1','{"studentId":"s1","centerId":"c1","teacherId":"t1","halaqaId":"h1","year":"2026","status":"نشط"}'),
 ('enrollments','e9','{"studentId":"s9","centerId":"c2","teacherId":"t2","halaqaId":"h2","year":"2026","status":"نشط"}');
update app_config set value='true' where key='rls_on';

-- ===== 1) حفظ الحصة: يعمل، ويعيد التطبيق بلا تكرار =====
set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
select public.save_session('sess1', '{"date":"2026-10-01","teacherId":"t1","status":"تمت"}', '2026-10-01',
  '{"s0":"p","s1":"a"}',
  '{"s0":{"rec":[{"id":"r1","d":"2026-10-01","g":"excellent","sessionId":"sess1"},{"id":"r2","d":"2026-10-01","g":"good","sessionId":"sess1"}],"rash":[]}}',
  '{"s0":{"studentId":"s0","page":3}}');
select public.save_session('sess1', '{"date":"2026-10-01","teacherId":"t1","status":"تمت"}', '2026-10-01',
  '{"s0":"p","s1":"a"}',
  '{"s0":{"rec":[{"id":"r1","d":"2026-10-01","g":"excellent","sessionId":"sess1"},{"id":"r2","d":"2026-10-01","g":"good","sessionId":"sess1"}],"rash":[]}}',
  '{"s0":{"studentId":"s0","page":3}}');
do $$ begin
  assert (select jsonb_array_length(data->'rec') from docs where col='prog' and id='s0') = 2, 'rec duplicated after re-save';
  assert (select data->'marks' from docs where col='attendance' and id='2026-10-01') = '{"s0":"p","s1":"a"}', 'marks wrong';
  assert exists(select 1 from docs where col='sessions' and id='sess1'), 'session missing';
  assert exists(select 1 from docs where col='homework' and id='s0'), 'homework missing';
end $$;
-- معلم آخر لنفس اليوم لا يمحو علامات الأول
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000e"}';
select public.save_session('sess2', '{"date":"2026-10-01","teacherId":"t2"}', '2026-10-01', '{"s9":"l"}', '{}', '{}');
do $$ begin
  assert (select data->'marks' from docs where col='attendance' and id='2026-10-01') = '{"s0":"p","s1":"a","s9":"l"}', 'marks of other teacher lost';
end $$;
-- معلم لا يكتب في مركز آخر
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $$ begin
  begin
    insert into docs(col,id,data) values ('students','bad','{"centerId":"c2"}');
    raise exception 'SHOULD FAIL';
  exception when insufficient_privilege then null; end;
end $$;

-- ===== 2) الذرّية: فشل في آخر خطوة يلغي كل ما قبله =====
reset role;
create or replace function _boom() returns trigger language plpgsql as $$ begin if new.id='boom' then raise exception 'boom'; end if; return new; end $$;
create trigger _boom_trg before insert on docs for each row execute function _boom();
set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $$ begin
  begin
    perform public.save_session('boom', '{"date":"2026-10-02"}', '2026-10-02', '{"s0":"p"}', '{"s1":{"rec":[{"id":"z","d":"2026-10-02","g":"good","sessionId":"boom"}]}}', '{}');
    raise exception 'SHOULD FAIL';
  exception when others then
    if sqlerrm = 'SHOULD FAIL' then raise; end if;
  end;
end $$;
reset role;
do $$ begin
  assert not exists(select 1 from docs where col='attendance' and id='2026-10-02'), 'attendance leaked after failed save';
  assert (select jsonb_array_length(coalesce(data->'rec','[]')) from docs where col='prog' and id='s1') is null, 'prog leaked after failed save';
end $$;
drop trigger _boom_trg on docs; drop function _boom();

-- ===== 3) أمان القراءة والنقاط =====
set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000c"}';   -- الطالب s0
do $$ declare r jsonb; begin
  assert (select count(*) from docs where col='prog') = 1 and (select count(*) from docs where col='students') = 1, 'student sees more than his rows';
  assert (select count(*) from profiles) = 1, 'student sees other profiles';
  begin perform public.student_points('s9'); raise exception 'SHOULD FAIL'; exception when insufficient_privilege then null; end;
  begin perform public.student_points('s1'); raise exception 'SHOULD FAIL'; exception when insufficient_privilege then null; end;
  r := public.student_points('s0');
  assert (r->>'total')::numeric = 1+3+1 + 0, 'own points wrong: '||r::text;      -- حضور 1 + ممتاز 3 + جيد 1
  r := public.halaqa_rank('s0');
  assert (r->>'rank')::int = 1 and (r->>'of')::int = 2, 'rank wrong: '||r::text;
  assert (select count(*) from public.leaderboard()) = 1, 'leaderboard leaks other students';
  assert (select count(*) from jsonb_object_keys(public.points_many(array['s0','s1','s9']))) = 1, 'points_many leaks other students';
  assert public.points_many(array['s0'])->'s0' = public.student_points('s0'), 'points_many <> student_points';
  assert public.points_server_enabled() = false, 'points_server should be off by default';
end $$;
-- طالب غير مسجَّل في أي حلقة: لا يرى شيئاً، ولا يُحسب للجميع (إصلاح leaderboard)
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000f"}';
do $$ begin
  assert (select count(*) from public.leaderboard()) = 0, 'unenrolled student should see empty leaderboard';
  assert (select count(*) from jsonb_object_keys(public.points_many(array['s0','s1']))) = 0, 'unenrolled student sees others via points_many';
  assert (public.points_many(array[]::text[])) = '{}'::jsonb, 'empty array should give empty object';
end $$;
reset role; set local role anon;
do $$ begin
  begin perform public.save_session('x','{"a":1}','2026-10-01'); raise exception 'SHOULD FAIL'; exception when insufficient_privilege then null; end;
  begin perform public.leaderboard(); raise exception 'SHOULD FAIL'; exception when insufficient_privilege then null; end;
end $$;
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';   -- مدير عام
do $$ begin
  assert (select count(*) from public.leaderboard()) = 3, 'gm should see all 3 active students';
  assert (select name from public.leaderboard() limit 1) = 'أحمد', 'leaderboard order wrong';
  assert (select count(*) from jsonb_object_keys(public.points_many(array['s0','s1','s9']))) = 3, 'gm points_many should see all';
end $$;

-- ===== 3b) إصلاحات المراجعة: null / تكرار المعرّفات / تاريخ الحصة =====
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
do $$ begin
  begin perform public.points_many(null); raise exception 'SHOULD FAIL'; exception when invalid_parameter_value then null; end;
  assert public.points_many(array['s0','s0','s0'])->'s0' = public.student_points('s0'), 'duplicate sids inflate points';
  assert (public.points_many(array['s0','s0'])->'s0'->>'p')::int = 1, 'duplicate sids double-count attendance';
  assert (select count(*) from jsonb_object_keys(public.points_many(array['s0','s0','s1']))) = 2, 'dedupe changed key count';
end $$;
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
do $$ begin
  begin perform public.save_session('bd1','{"a":1}','not-a-date'); raise exception 'SHOULD FAIL'; exception when invalid_parameter_value then null; end;
  begin perform public.save_session('bd2','{"a":1}','2026-02-31'); raise exception 'SHOULD FAIL'; exception when invalid_parameter_value then null; end;
  begin perform public.save_session('bd3','{"a":1}',null); raise exception 'SHOULD FAIL'; exception when invalid_parameter_value then null; end;
  assert not exists(select 1 from docs where col='sessions' and id in ('bd1','bd2','bd3')), 'bad-date session was saved';
end $$;
reset role; set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';

-- ===== 4) الأرشفة: محروسة، ولا تغيّر النقاط =====
do $$ begin
  begin perform public.archive_attendance('2026-01-01'); raise exception 'SHOULD FAIL'; exception when object_not_in_prerequisite_state then null; end;
end $$;
reset role;
insert into app_config(key,value) values ('points_server','true') on conflict (key) do update set value='true';
insert into docs(col,id,data) values ('attendance','2025-01-05','{"marks":{"s0":"p"}}'),('attendance','2025-01-06','{"marks":{"s0":"a"}}');
set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
create temp table _before as select public.student_points('s0') as j;
select public.archive_attendance('2026-01-01') as archived;
do $$ begin
  assert (select count(*) from docs where col='attendance' and id < '2026-01-01') = 0, 'old attendance not removed from docs';
  assert (public.student_points('s0')) = (select j from _before), 'points changed after archive';
end $$;
select public.restore_attendance('2025-01-01','2025-12-31') as restored;
do $$ begin assert (select count(*) from docs where col='attendance' and id < '2026-01-01') = 2, 'restore failed'; end $$;
reset role;

-- ===== 5) الأداء: حفظ حصة بـ 200 طالب في أقل من ثانية =====
set local role authenticated; set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
do $$ declare t0 timestamptz := clock_timestamp(); marks jsonb; prog jsonb; i int; ms numeric;
begin
  select jsonb_object_agg('p'||g, 'p'), jsonb_object_agg('p'||g, jsonb_build_object('rec', jsonb_build_array(jsonb_build_object('id','x'||g,'d','2026-10-03','g','good','sessionId','perf'))))
    into marks, prog from generate_series(1,200) g;
  perform public.save_session('perf', '{"date":"2026-10-03"}', '2026-10-03', marks, prog, '{}');
  ms := extract(milliseconds from clock_timestamp() - t0);
  raise notice 'save_session(200 طالب) = % ms', ms;
  assert ms < 1000, 'save_session slower than 1s: '||ms;
end $$;
rollback;
\echo ALL TESTS PASSED
