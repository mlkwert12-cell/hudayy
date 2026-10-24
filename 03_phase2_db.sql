-- =====================================================================
-- 03_phase2_db.sql  —  المرحلة 2 (دفعة قاعدة البيانات): 2.3 + 2.6
--   • save_session()      : حفظ الحصة كاملة (حضور + تسميع + واجب + وثيقة الحصة) في معاملة واحدة
--   • points_calc() ...   : حساب النقاط على الخادم (مطابق لـ pointsOf في الواجهة)
--   • student_points / leaderboard / halaqa_rank : واجهات النقاط للتطبيق
--   • docs_archive        : أرشفة الحضور القديم (محروسة؛ لا تعمل قبل تحويل الواجهة للنقاط من الخادم)
-- شغّله بعد 01 و 02. آمن لإعادة التشغيل. لا يغيّر سلوك التطبيق الحالي إلى أن تستدعيه الواجهة.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) أدوات مساعدة
-- ---------------------------------------------------------------------
-- نظير num() في الواجهة: أي قيمة غير رقمية = 0
create or replace function public._num(v jsonb) returns numeric
language sql immutable parallel safe as $$
  select case jsonb_typeof(v)
    when 'number'  then (v #>> '{}')::numeric
    when 'boolean' then case when (v #>> '{}') = 'true' then 1 else 0 end
    when 'string'  then case
        when btrim(v #>> '{}') = '' then 0
        when (v #>> '{}') ~ '^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\s*$' then btrim(v #>> '{}')::numeric
        else 0 end
    else 0 end
$$;

-- ---------------------------------------------------------------------
-- 1) أرشيف الحضور (2.6)
-- ---------------------------------------------------------------------
create table if not exists public.docs_archive (
  col text not null, id text not null, data jsonb,
  updated_at timestamptz, updated_by uuid, archived_at timestamptz not null default now(),
  primary key (col, id)
);
alter table public.docs_archive enable row level security;       -- بلا سياسات: لا يصل إليه إلا الدوال
revoke all on public.docs_archive from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) النقاط على الخادم (2.3) — مطابقة حرفية لمنطق pointsOf()
-- ---------------------------------------------------------------------
create or replace function public.points_rules() returns jsonb
language sql stable security definer set search_path = public set row_security = off as $$
  select '{"present":1,"late":-2,"absent":-2,"good":1,"vgood":2,"excellent":3,"redo":-3,
           "streakDays":15,"streakBonus":15,"examFactor":1}'::jsonb
         || coalesce((select case when jsonb_typeof(d.data->'rules') = 'object' then d.data->'rules' end
                        from public.docs d where d.col = 'settings' and d.id = 'main'), '{}'::jsonb)
$$;

-- الحساب الأساسي (داخلي). p_sids = null يعني كل الطلاب الذين لهم حضور أو سجل.
create or replace function public.points_calc(p_from text, p_to text, p_sids text[] default null)
returns table(sid text, att numeric, rec numeric, exam numeric, adds numeric, streak numeric,
              p int, l int, a int, n_rec int, n_exam int, n_add int, total numeric)
language plpgsql stable security definer set search_path = public set row_security = off as $$
#variable_conflict use_column
declare
  r   jsonb   := public.points_rules();
  f   text    := nullif(p_from, '');
  t   text    := nullif(p_to, '');
  v_present numeric := public._num(r->'present');
  v_late    numeric := public._num(r->'late');
  v_absent  numeric := public._num(r->'absent');
  v_sdays   numeric := public._num(r->'streakDays');
  v_sbonus  numeric := public._num(r->'streakBonus');
  v_xf      float8  := public._num(r->'examFactor')::float8;
begin
  -- إزالة تكرار المعرّفات: التكرار كان يضاعف الحضور (unnest في mk) 
  if p_sids is not null then
    p_sids := array(select distinct u from unnest(p_sids) as u where u is not null);
  end if;
  return query
  with cd as (   -- أيام الحصص ضمن المدى (كما D.classDates)
    select x.id as d, row_number() over (order by x.id collate "C") as idx, x.data->'marks' as marks
      from (select d.id, d.data from public.docs d where d.col = 'attendance'
            union all
            select a.id, a.data from public.docs_archive a where a.col = 'attendance') x
     where jsonb_typeof(x.data->'marks') = 'object' and x.data->'marks' <> '{}'::jsonb
       and (f is null or x.id >= f) and (t is null or x.id <= t)
  ),
  mk as (
    select cd.idx, u.sid, cd.marks->>u.sid as st                  -- قائمة محدّدة: بحث بالمفتاح (سريع)
      from cd cross join unnest(p_sids) as u(sid)
     where p_sids is not null and cardinality(p_sids) <= 1000 and cd.marks ? u.sid
    union all
    select cd.idx, m.key, m.value                                  -- قائمة كبيرة أو الكل: تفكيك العلامات (+ ربط تجزئة)
      from cd, jsonb_each_text(cd.marks) m
     where p_sids is null or (cardinality(p_sids) > 1000 and m.key in (select unnest(p_sids)))
  ),
  pr as (        -- أيام الحضور المتتالية (تُكسر بأي يوم غير حاضر أو بلا علامة)
    select sid, idx, idx - row_number() over (partition by sid order by idx) as grp
      from mk where st = 'p'
  ),
  runs as (
    select sid, row_number() over (partition by sid, grp order by idx) as run from pr
  ),
  att as (
    select mk.sid,
           sum(case mk.st when 'p' then v_present when 'l' then v_late when 'a' then v_absent else 0 end) as att,
           count(*) filter (where mk.st = 'p')::int as p,
           count(*) filter (where mk.st = 'l')::int as l,
           count(*) filter (where mk.st = 'a')::int as a
      from mk group by mk.sid
  ),
  stk as (
    select runs.sid, sum(case when v_sdays > 0 and runs.run % v_sdays = 0 then v_sbonus else 0 end) as streak
      from runs group by runs.sid
  ),
  pg as (
    select d.id as sid, d.data from public.docs d
     where d.col = 'prog' and (p_sids is null or d.id = any(p_sids))
  ),
  rc as (
    select pg.sid, coalesce(sum(public._num(r -> (e->>'g'))), 0) as rec, count(*)::int as n
      from pg, jsonb_array_elements(case when jsonb_typeof(pg.data->'rec') = 'array' then pg.data->'rec' else '[]'::jsonb end) e
     where f is null and t is null or ((f is null or e->>'d' >= f) and (t is null or e->>'d' <= t))
     group by pg.sid
  ),
  ex as (
    select pg.sid,
           coalesce(sum(floor(
             public._num(e->'mark')::float8
             / (case when public._num(e->'max') = 0 then 100 else public._num(e->'max') end)::float8
             * 100 * v_xf + 0.5)), 0)::numeric as exam, count(*)::int as n
      from pg, jsonb_array_elements(case when jsonb_typeof(pg.data->'exams') = 'array' then pg.data->'exams' else '[]'::jsonb end) e
     where f is null and t is null or ((f is null or e->>'d' >= f) and (t is null or e->>'d' <= t))
     group by pg.sid
  ),
  ad as (
    select pg.sid, coalesce(sum(public._num(e->'points')), 0) as adds, count(*)::int as n
      from pg, jsonb_array_elements(case when jsonb_typeof(pg.data->'adds') = 'array' then pg.data->'adds' else '[]'::jsonb end) e
     where f is null and t is null or ((f is null or e->>'d' >= f) and (t is null or e->>'d' <= t))
     group by pg.sid
  ),
  ids as (
    select unnest(p_sids) as sid where p_sids is not null
    union select att.sid from att where p_sids is null
    union select rc.sid from rc where p_sids is null
    union select ex.sid from ex where p_sids is null
    union select ad.sid from ad where p_sids is null
  )
  select ids.sid,
         coalesce(att.att, 0), coalesce(rc.rec, 0), coalesce(ex.exam, 0), coalesce(ad.adds, 0), coalesce(stk.streak, 0),
         coalesce(att.p, 0), coalesce(att.l, 0), coalesce(att.a, 0),
         coalesce(rc.n, 0), coalesce(ex.n, 0), coalesce(ad.n, 0),
         coalesce(att.att, 0) + coalesce(rc.rec, 0) + coalesce(ex.exam, 0) + coalesce(ad.adds, 0) + coalesce(stk.streak, 0)
    from ids
    left join att on att.sid = ids.sid left join stk on stk.sid = ids.sid
    left join rc  on rc.sid  = ids.sid left join ex  on ex.sid  = ids.sid left join ad on ad.sid = ids.sid;
end $$;

-- هل يحق للمستخدم الحالي رؤية نقاط هذا الطالب؟ (نفس نطاق سياسات docs)
create or replace function public._can_see_student(p_sid text) returns boolean
language sql stable security definer set search_path = public set row_security = off as $$
  select not public.app_rls_on()
      or public.app_role() in ('gm', 'admin', 'staff', 'viewer')
      or p_sid = any(public.app_student_ids())
$$;

-- نقاط طالب واحد (نفس شكل ناتج pointsOf)
create or replace function public.student_points(p_sid text, p_from text default null, p_to text default null)
returns jsonb
language plpgsql stable security definer set search_path = public set row_security = off as $$
declare x record;
begin
  if not public._can_see_student(p_sid) then
    raise exception 'غير مسموح' using errcode = '42501';
  end if;
  select * into x from public.points_calc(p_from, p_to, array[p_sid]);
  return jsonb_build_object('att', x.att, 'rec', x.rec, 'exam', x.exam, 'add', x.adds, 'streak', x.streak,
    'p', x.p, 'l', x.l, 'a', x.a, 'nRec', x.n_rec, 'nExam', x.n_exam, 'nAdd', x.n_add, 'total', x.total);
end $$;

-- نقاط عدة طلاب دفعة واحدة (للواجهة): {"<sid>": {...}}؛ الطلاب خارج النطاق يُتجاهلون بصمت
create or replace function public.points_many(p_sids text[], p_from text default null, p_to text default null)
returns jsonb
language plpgsql stable security definer set search_path = public set row_security = off as $$
#variable_conflict use_column
declare ids text[]; res jsonb;
begin
  if p_sids is null then
    raise exception 'points_many: p_sids مطلوب (null يعني كل الطلاب وهو غير مسموح هنا)' using errcode = '22023';
  end if;
  if coalesce(array_length(p_sids, 1), 0) > 500 then
    raise exception 'points_many: الحد الأقصى 500 طالب في الطلب' using errcode = '22023';
  end if;
  if not public.app_rls_on() or public.app_role() in ('gm', 'admin', 'staff', 'viewer') then
    ids := p_sids;
  else
    ids := array(select unnest(p_sids) intersect select unnest(public.app_student_ids()));
  end if;
  select coalesce(jsonb_object_agg(x.sid, jsonb_build_object('att', x.att, 'rec', x.rec, 'exam', x.exam, 'add', x.adds,
           'streak', x.streak, 'p', x.p, 'l', x.l, 'a', x.a, 'nRec', x.n_rec, 'nExam', x.n_exam, 'nAdd', x.n_add,
           'total', x.total)), '{}'::jsonb)
    into res from public.points_calc(p_from, p_to, ids) x;
  return res;
end $$;

-- هل تحسب الواجهة النقاط من الخادم؟ (app_config.points_server)
create or replace function public.points_server_enabled() returns boolean
language sql stable security definer set search_path = public set row_security = off as $$
  select coalesce((select value from public.app_config where key = 'points_server'), 'false') = 'true'
$$;

-- لوحة الشرف: الطلاب النشطون في السنة (ضمن نطاق المستخدم)، مرتبون بالنقاط
create or replace function public.leaderboard(p_from text default null, p_to text default null,
                                              p_year text default null, p_halaqa text default null, p_limit int default 50)
returns table(sid text, name text, no text, total numeric, att numeric, rec numeric, exam numeric, adds numeric, streak numeric)
language plpgsql stable security definer set search_path = public set row_security = off as $$
#variable_conflict use_column
declare yr text := coalesce(p_year, (select d.data->>'currentYear' from public.docs d where d.col = 'settings' and d.id = 'main'));
begin
  return query
  with en as (
    select distinct e.student_id as sid
      from public.docs e
     where e.col = 'enrollments' and e.data->>'year' is not distinct from yr and e.data->>'status' = 'نشط'
       and e.student_id is not null and (p_halaqa is null or e.halaqa_id = p_halaqa)
  ),
  vis as (select en.sid from en where public._can_see_student(en.sid)),
  pc  as (select * from public.points_calc(p_from, p_to, coalesce((select array_agg(vis.sid) from vis), '{}'::text[])))
  select s.id, s.data->>'name', s.data->>'no', pc.total, pc.att, pc.rec, pc.exam, pc.adds, pc.streak
    from vis join pc on pc.sid = vis.sid
    join public.docs s on s.col = 'students' and s.id = vis.sid
   order by pc.total desc, (s.data->>'name') collate "C"
   limit greatest(1, least(coalesce(p_limit, 50), 500));
end $$;

-- ترتيب الطالب داخل حلقته بدون كشف أسماء الزملاء (للبوابة)
create or replace function public.halaqa_rank(p_sid text, p_from text default null, p_to text default null, p_year text default null)
returns jsonb
language plpgsql stable security definer set search_path = public set row_security = off as $$
declare
  yr text := coalesce(p_year, (select d.data->>'currentYear' from public.docs d where d.col = 'settings' and d.id = 'main'));
  h text; mine numeric; n int; rk int;
begin
  if not public._can_see_student(p_sid) then raise exception 'غير مسموح' using errcode = '42501'; end if;
  select e.halaqa_id into h from public.docs e
   where e.col = 'enrollments' and e.student_id = p_sid and e.data->>'year' is not distinct from yr
     and e.data->>'status' = 'نشط' limit 1;
  if h is null then return jsonb_build_object('rank', null, 'of', 0, 'total', 0); end if;
  with peers as (
    select distinct e.student_id as sid from public.docs e
     where e.col = 'enrollments' and e.halaqa_id = h and e.data->>'year' is not distinct from yr
       and e.data->>'status' = 'نشط' and e.student_id is not null
  ), pc as (select * from public.points_calc(p_from, p_to, coalesce((select array_agg(peers.sid) from peers), '{}'::text[])))
  select (select pc.total from pc where pc.sid = p_sid), count(*)::int,
         1 + count(*) filter (where pc.total > (select pc2.total from pc pc2 where pc2.sid = p_sid))::int
    into mine, n, rk from pc;
  return jsonb_build_object('rank', rk, 'of', n, 'total', coalesce(mine, 0));
end $$;

-- ---------------------------------------------------------------------
-- 3) حفظ الحصة كاملة في معاملة واحدة (2.3)
--    الواجهة تبني الإدخالات كما تفعل اليوم (absToJP, التلقين...) وترسلها دفعة واحدة؛
--    الخادم يطبّق الدمج ذرّياً (يحلّ سباق القراءة-ثم-الكتابة في saveProg).
--    SECURITY INVOKER: سياسات RLS للمستخدم تُطبَّق على كل صف.
--      p_session  : وثيقة الحصة (تُحفظ في docs.sessions/p_session_id)
--      p_date     : تاريخ الحصة (معرّف وثيقة الحضور)
--      p_marks    : {"<sid>":"p|l|a"}  (يُدمج مع علامات المعلمين الآخرين لنفس اليوم)
--      p_prog     : {"<sid>":{"rec":[...],"rash":[...]}}  إدخالات هذه الحصة فقط (مصفوفة فارغة = حذف إدخالاتها السابقة)
--      p_homework : {"<sid>":{...وثيقة الواجب}}
-- ---------------------------------------------------------------------
create or replace function public.save_session(p_session_id text, p_session jsonb, p_date text,
                                               p_marks jsonb default '{}', p_prog jsonb default '{}',
                                               p_homework jsonb default '{}')
returns jsonb
language plpgsql security invoker as $$
declare
  k text; v jsonb; cur jsonb; n_prog int := 0; n_hw int := 0; n_marks int := 0;
begin
  if coalesce(p_session_id, '') = '' or jsonb_typeof(p_session) <> 'object' then
    raise exception 'save_session: بيانات الحصة ناقصة' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_marks, '{}')) <> 'object' or jsonb_typeof(coalesce(p_prog, '{}')) <> 'object'
     or jsonb_typeof(coalesce(p_homework, '{}')) <> 'object' then
    raise exception 'save_session: p_marks/p_prog/p_homework يجب أن تكون كائنات' using errcode = '22023';
  end if;
  if p_date is null or p_date !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'save_session: p_date يجب أن يكون YYYY-MM-DD' using errcode = '22023';
  end if;
  begin
    perform p_date::date;   -- يرفض التواريخ المستحيلة مثل 2026-02-31
  exception when others then
    raise exception 'save_session: p_date تاريخ غير صالح' using errcode = '22023';
  end;
  if jsonb_object_keys_count(p_prog) > 500 or jsonb_object_keys_count(p_marks) > 2000 then
    raise exception 'save_session: حجم الطلب كبير' using errcode = '22023';
  end if;

  -- 1) الحضور (دمج ذرّي)
  if p_marks is not null and p_marks <> '{}'::jsonb then
    perform public.merge_marks('attendance', p_date, p_marks);
    n_marks := jsonb_object_keys_count(p_marks);
  end if;

  -- 2) سجل الحفظ لكل طالب: احذف إدخالات هذه الحصة ثم أضف الجديدة (بقفل الصف)
  for k, v in select * from jsonb_each(coalesce(p_prog, '{}')) loop
    select data into cur from public.docs where col = 'prog' and id = k for update;
    cur := coalesce(cur, '{}'::jsonb);
    cur := jsonb_build_object(
      'rec',   coalesce((select jsonb_agg(x) from jsonb_array_elements(case when jsonb_typeof(cur->'rec')  = 'array' then cur->'rec'  else '[]' end) x
                          where x->>'sessionId' is distinct from p_session_id), '[]'::jsonb)
               || case when jsonb_typeof(v->'rec')  = 'array' then v->'rec'  else '[]'::jsonb end,
      'rash',  coalesce((select jsonb_agg(x) from jsonb_array_elements(case when jsonb_typeof(cur->'rash') = 'array' then cur->'rash' else '[]' end) x
                          where x->>'sessionId' is distinct from p_session_id), '[]'::jsonb)
               || case when jsonb_typeof(v->'rash') = 'array' then v->'rash' else '[]'::jsonb end,
      'exams', case when jsonb_typeof(cur->'exams') = 'array' then cur->'exams' else '[]'::jsonb end,
      'adds',  case when jsonb_typeof(cur->'adds')  = 'array' then cur->'adds'  else '[]'::jsonb end
    ) || (cur - 'rec' - 'rash' - 'exams' - 'adds');
    insert into public.docs (col, id, data, updated_at, updated_by)
    values ('prog', k, cur, now(), auth.uid())
    on conflict (col, id) do update set data = excluded.data, updated_at = now(), updated_by = auth.uid();
    n_prog := n_prog + 1;
  end loop;

  -- 3) الواجب
  for k, v in select * from jsonb_each(coalesce(p_homework, '{}')) loop
    insert into public.docs (col, id, data, updated_at, updated_by)
    values ('homework', k, v, now(), auth.uid())
    on conflict (col, id) do update set data = excluded.data, updated_at = now(), updated_by = auth.uid();
    n_hw := n_hw + 1;
  end loop;

  -- 4) وثيقة الحصة (آخراً: لو فشل أي شيء قبلها تُلغى المعاملة كلها)
  insert into public.docs (col, id, data, updated_at, updated_by)
  values ('sessions', p_session_id, p_session, now(), auth.uid())
  on conflict (col, id) do update set data = excluded.data, updated_at = now(), updated_by = auth.uid();

  return jsonb_build_object('ok', true, 'marks', n_marks, 'prog', n_prog, 'homework', n_hw);
end $$;

create or replace function public.jsonb_object_keys_count(j jsonb) returns int
language sql immutable parallel safe as $$
  select case when jsonb_typeof(j) = 'object' then (select count(*)::int from jsonb_object_keys(j)) else 0 end
$$;

-- ---------------------------------------------------------------------
-- 4) أرشفة الحضور القديم (2.6) — محروسة
--    لا تعمل إلا بعد تحويل الواجهة لجلب النقاط من الخادم، وإلا ستتغيّر «نقاطي» في المتصفح
--    (لأنها تُحسب اليوم من كل أيام الحضور المحمّلة). النقاط على الخادم تقرأ الأرشيف أيضاً فلا تتغيّر.
--    التفعيل:  insert into app_config(key,value) values ('points_server','true') on conflict (key) do update set value='true';
-- ---------------------------------------------------------------------
create or replace function public.archive_attendance(p_before text) returns integer
language plpgsql security definer set search_path = public set row_security = off as $$
declare n int;
begin
  if auth.uid() is not null and public.app_role() not in ('gm', 'admin') then
    raise exception 'غير مسموح' using errcode = '42501';
  end if;
  if coalesce((select value from public.app_config where key = 'points_server'), 'false') <> 'true' then
    raise exception 'الواجهة لم تُحوَّل بعد للنقاط من الخادم (app_config.points_server)؛ الأرشفة ستغيّر النقاط المعروضة' using errcode = '55000';
  end if;
  if p_before !~ '^\d{4}-\d{2}-\d{2}$' or p_before > to_char(current_date - 90, 'YYYY-MM-DD') then
    raise exception 'p_before يجب أن يكون تاريخاً (YYYY-MM-DD) أقدم من 90 يوماً' using errcode = '22023';
  end if;
  with mv as (
    delete from public.docs where col = 'attendance' and id < p_before returning col, id, data, updated_at, updated_by
  ) insert into public.docs_archive (col, id, data, updated_at, updated_by)
    select col, id, data, updated_at, updated_by from mv
    on conflict (col, id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.restore_attendance(p_from text, p_to text) returns integer
language plpgsql security definer set search_path = public set row_security = off as $$
declare n int;
begin
  if auth.uid() is not null and public.app_role() not in ('gm', 'admin') then
    raise exception 'غير مسموح' using errcode = '42501';
  end if;
  with mv as (
    delete from public.docs_archive where col = 'attendance' and id between p_from and p_to
    returning col, id, data, updated_at, updated_by
  ) insert into public.docs (col, id, data, updated_at, updated_by)
    select col, id, data, updated_at, updated_by from mv on conflict (col, id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 5) الصلاحيات
-- ---------------------------------------------------------------------
revoke execute on function public.points_calc(text, text, text[])            from public, anon, authenticated;
revoke execute on function public.points_rules()                             from public, anon;
revoke execute on function public._can_see_student(text)                     from public, anon;
revoke execute on function public._num(jsonb)                                from public, anon;
revoke execute on function public.jsonb_object_keys_count(jsonb)             from public, anon;
grant  execute on function public._num(jsonb), public.jsonb_object_keys_count(jsonb), public.points_rules(),
                           public._can_see_student(text)                     to authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.student_points(text,text,text)', 'public.points_many(text[],text,text)', 'public.points_server_enabled()', 'public.leaderboard(text,text,text,text,int)',
    'public.halaqa_rank(text,text,text,text)', 'public.save_session(text,jsonb,text,jsonb,jsonb,jsonb)',
    'public.archive_attendance(text)', 'public.restore_attendance(text,text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
