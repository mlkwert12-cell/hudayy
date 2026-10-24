-- =====================================================================
-- 02_rls_shadow.sql  —  سياسات RLS في «وضع الظل»
-- لا يغيّر أي سلوك حالي: كل السياسات تبدأ بـ (not app_rls_on()) فتبقى مفتوحة
-- إلى أن تنفّذ 02b_enforce_rls.sql بعد الاختبار.
-- شغّل 01_indexes_and_rpc.sql أولاً. يمكن إعادة تشغيل هذا الملف.
-- يغطي المهمة 1.8
-- =====================================================================

-- 0) مفتاح التشغيل
create table if not exists public.app_config (key text primary key, value text not null);
insert into public.app_config(key, value) values ('rls_on', 'false') on conflict (key) do nothing;
alter table public.app_config enable row level security;   -- بلا سياسات: لا يقرؤه إلا الدوال

create or replace function public.app_rls_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true' from public.app_config where key = 'rls_on'), false)
$$;

-- 1) هوية المستخدم ونطاقه (نفس منطق computeMe() في الواجهة)
create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'pending')
$$;

create or replace function public.app_ctx() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  p jsonb; r text; em text; no int;
  t text; s text; c text; rg text; d text; row_ jsonb;
begin
  select to_jsonb(x) into p from public.profiles x where x.id = auth.uid();
  if p is null then return jsonb_build_object('role', 'pending'); end if;
  r  := coalesce(p->>'role', 'pending');
  em := coalesce((select u.email from auth.users u where u.id = auth.uid()), p->>'email', '');
  no := nullif(substring(em from '^u-(\d+)@'), '')::int;

  if r in ('student', 'parent') then
    s := nullif(p->>'student_id', '');
    if no is not null then
      select dd.id into s from public.docs dd
       where dd.col = 'students'
         and nullif(regexp_replace(coalesce(dd.data->>'self_no', ''), '\D', '', 'g'), '')::int = no
       limit 1;
      s := coalesce(s, nullif(p->>'student_id', ''));
    end if;
  elsif r = 'teacher' then
    t := nullif(p->>'teacher_id', '');
    if t is null and no is not null then
      select dd.id into t from public.docs dd
       where dd.col = 'teachers'
         and nullif(regexp_replace(coalesce(dd.data->>'self_no', ''), '\D', '', 'g'), '')::int = no
       limit 1;
    end if;
    if t is not null then
      select dd.center_id into c from public.docs dd where dd.col = 'teachers' and dd.id = t;
    end if;
  elsif r in ('am', 'rm', 'cs') and no is not null then
    select dd.data into row_ from public.docs dd
     where dd.col = 'supervisors'
       and nullif(regexp_replace(coalesce(dd.data->>'self_no', ''), '\D', '', 'g'), '')::int = no
     limit 1;
    if row_ is not null then
      d := nullif(row_->>'deptId', ''); rg := nullif(row_->>'regionId', ''); c := nullif(row_->>'centerId', '');
    end if;
  end if;

  -- القيم في profiles تتغلّب (كما في الواجهة)
  d  := coalesce(nullif(p->>'dept_id', ''),   d);
  rg := coalesce(nullif(p->>'region_id', ''), rg);
  c  := coalesce(nullif(p->>'center_id', ''), c);

  return jsonb_build_object('role', r, 'uid', auth.uid()::text,
    'teacher_id', t, 'student_id', s, 'center_id', c, 'region_id', rg, 'dept_id', d);
end;
$$;

create or replace function public.app_student_id() returns text
language sql stable security definer set search_path = public as $$ select public.app_ctx()->>'student_id' $$;
create or replace function public.app_teacher_id() returns text
language sql stable security definer set search_path = public as $$ select public.app_ctx()->>'teacher_id' $$;

-- 2) مجموعات النطاق (مصفوفات تُحسب مرة واحدة لكل استعلام عبر (select fn()))
create or replace function public.app_dept_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); res text[];
begin
  select coalesce(array_agg(distinct x), '{}') into res from (
    select c->>'dept_id' as x where c->>'dept_id' is not null
    union
    select d.data->>'deptId' from public.docs d
     where d.col = 'regions' and d.id = any(public.app_region_ids()) and d.data->>'deptId' is not null
  ) q;
  return res;
end; $$;

create or replace function public.app_center_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); r text := c->>'role'; res text[] := '{}';
begin
  if r = 'am' then
    select coalesce(array_agg(d.id), '{}') into res from public.docs d
     where d.col = 'centers' and d.region_id in (
       select g.id from public.docs g
        where g.col = 'regions' and c->>'dept_id' is not null and g.data->>'deptId' = c->>'dept_id');
  elsif r = 'rm' then
    if c->>'region_id' is not null then
      select coalesce(array_agg(d.id), '{}') into res from public.docs d
       where d.col = 'centers' and d.region_id = c->>'region_id';
    end if;
  elsif r in ('cs', 'teacher') then
    if c->>'center_id' is not null then res := array[c->>'center_id']; end if;
  elsif r in ('student', 'parent') then
    select coalesce(array_agg(distinct e.center_id), '{}') into res from public.docs e
     where e.col = 'enrollments' and e.student_id = c->>'student_id' and e.center_id is not null;
  end if;
  return res;
end; $$;

create or replace function public.app_region_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); r text := c->>'role'; res text[] := '{}';
begin
  if r = 'am' then
    select coalesce(array_agg(g.id), '{}') into res from public.docs g
     where g.col = 'regions' and c->>'dept_id' is not null and g.data->>'deptId' = c->>'dept_id';
  elsif r = 'rm' then
    if c->>'region_id' is not null then res := array[c->>'region_id']; end if;
  else
    select coalesce(array_agg(distinct d.region_id), '{}') into res from public.docs d
     where d.col = 'centers' and d.id = any(public.app_center_ids()) and d.region_id is not null;
  end if;
  return res;
end; $$;

create or replace function public.app_enrollment_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); r text := c->>'role'; res text[] := '{}';
begin
  if r in ('student', 'parent') then
    select coalesce(array_agg(e.id), '{}') into res from public.docs e
     where e.col = 'enrollments' and e.student_id = c->>'student_id';
  elsif r = 'teacher' then
    if c->>'teacher_id' is not null then
      select coalesce(array_agg(e.id), '{}') into res from public.docs e
       where e.col = 'enrollments' and (
             e.teacher_id = c->>'teacher_id'
          or e.halaqa_id in (select h.id from public.docs h
                              where h.col = 'halaqat' and h.teacher_id = c->>'teacher_id'));
    end if;
  else
    select coalesce(array_agg(e.id), '{}') into res from public.docs e
     where e.col = 'enrollments' and e.center_id = any(public.app_center_ids());
  end if;
  return res;
end; $$;

create or replace function public.app_student_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); res text[];
begin
  select coalesce(array_agg(distinct x), '{}') into res from (
    select c->>'student_id' as x where c->>'student_id' is not null
    union
    select e.student_id from public.docs e
     where e.col = 'enrollments' and e.id = any(public.app_enrollment_ids()) and e.student_id is not null
  ) q;
  return res;
end; $$;

create or replace function public.app_halaqa_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); res text[];
begin
  select coalesce(array_agg(distinct x), '{}') into res from (
    select e.halaqa_id as x from public.docs e
     where e.col = 'enrollments' and e.id = any(public.app_enrollment_ids()) and e.halaqa_id is not null
    union
    select h.id from public.docs h
     where h.col = 'halaqat' and c->>'role' = 'teacher' and h.teacher_id = c->>'teacher_id'
  ) q;
  return res;
end; $$;

create or replace function public.app_teacher_ids() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := public.app_ctx(); r text := c->>'role'; res text[] := '{}';
begin
  if r = 'teacher' then
    if c->>'teacher_id' is not null then res := array[c->>'teacher_id']; end if;
  elsif r in ('student', 'parent') then
    select coalesce(array_agg(distinct x), '{}') into res from (
      select e.teacher_id as x from public.docs e
       where e.col = 'enrollments' and e.id = any(public.app_enrollment_ids()) and e.teacher_id is not null
      union
      select h.teacher_id from public.docs h
       where h.col = 'halaqat' and h.id = any(public.app_halaqa_ids()) and h.teacher_id is not null
    ) q;
  else
    select coalesce(array_agg(d.id), '{}') into res from public.docs d
     where d.col = 'teachers' and d.center_id = any(public.app_center_ids());
  end if;
  return res;
end; $$;

-- 3) السياسات (تُبنى بنص واحد حتى لا نكرّر شرط القراءة)
do $$
declare
  v_read  text;
  v_write text;
  rr text := '(select public.app_role())';
  uu text := '(select auth.uid()::text)';
  cs text := '((select public.app_center_ids())::text[])';   -- الـ cast ضروري: any((select arr)) تُقرأ كاستعلام فرعي وتفشل
begin
  v_read := $r$
       not public.app_rls_on()
    or $RR in ('gm','admin')
    or ($RR in ('staff','viewer') and col not in ('fees','payments'))
    or ($RR not in ('pending','') and col = 'settings')
    or ($RR in ('am','rm','cs','teacher','student','parent') and (
         (col = 'depts'    and id = any((select public.app_dept_ids())::text[]))
      or (col = 'regions'  and id = any((select public.app_region_ids())::text[]))
      or (col = 'centers'  and id = any($CS))
      or (col = 'halaqat'  and (case
             when $RR in ('student','parent') then id = any((select public.app_halaqa_ids())::text[])
             when $RR = 'teacher' then (teacher_id = (select public.app_teacher_id()) or id = any((select public.app_halaqa_ids())::text[]))
             else center_id = any($CS) end))
      or (col = 'students' and (id = any((select public.app_student_ids())::text[]) or created_by_app = $UU))
      or (col = 'enrollments' and id = any((select public.app_enrollment_ids())::text[]))
      or (col = 'teachers' and (case
             when $RR = 'teacher' then id = (select public.app_teacher_id())
             when $RR in ('student','parent') then id = any((select public.app_teacher_ids())::text[])
             else (center_id = any($CS) or created_by_app = $UU) end))
      or (col = 'supervisors' and $RR in ('am','rm','cs') and (
             created_by_app = $UU
          or region_id = any((select public.app_region_ids())::text[])
          or center_id = any($CS)
          or (data->>'deptId') = any((select public.app_dept_ids())::text[])))
      or (col = 'books'   and center_id = any($CS))
      or (col = 'lessons')
      -- المالية: لا يراها المعلم (غيّر السطر التالي إن أردت السماح له)
      or (col in ('fees','payments') and $RR <> 'teacher' and enrollment_id = any((select public.app_enrollment_ids())::text[]))
      -- ملاحظة: attendance/tattendance سجل واحد لكل يوم لكل المراكز؛ لا يمكن حجبه على مستوى الصف
      or col = 'attendance'
      or (col = 'tattendance' and $RR not in ('student','parent'))
      or (col = 'prog' and id = any((select public.app_student_ids())::text[]))
      or (col = 'tevals' and $RR not in ('student','parent') and teacher_id = any((select public.app_teacher_ids())::text[]))
      or (col = 'certificates' and (
             ((data->>'recipientType') = 'teacher' and $RR not in ('student','parent') and (data->>'recipientId') = any((select public.app_teacher_ids())::text[]))
          or (coalesce(data->>'recipientType','') <> 'teacher' and (data->>'recipientId') = any((select public.app_student_ids())::text[]))))
      or (col in ('studentnotes','exams','rashidiExams','homework') and student_id = any((select public.app_student_ids())::text[]))
      or (col = 'sessions' and (teacher_id = any((select public.app_teacher_ids())::text[]) or (data->>'savedBy') = $UU))
      or (col = 'recordings' and (case
             when $RR in ('student','parent') then student_id = (select public.app_student_id())
             when $RR = 'teacher' then (teacher_id = (select public.app_teacher_id()) or (data->>'by') = $UU)
             else false end))
      or (col = 'tickets' and ((data->>'by') = $UU or ($RR = 'rm' and region_id = any((select public.app_region_ids())::text[]))))
      or (col = 'mgrades' and $RR not in ('student','parent') and (case
             when $RR = 'teacher' then (teacher_id = (select public.app_teacher_id()) or ((data->>'kind') = 'cfg' and center_id = any($CS)))
             else center_id = any($CS) end))
      or (col = 'editRequests' and (teacher_id = any((select public.app_teacher_ids())::text[]) or (data->>'by') = $UU))
      or (col in ('msglog','msgsched') and $RR in ('am','rm','cs'))
      or (col = 'notifications')
    ))
  $r$;

  v_write := $r$
       not public.app_rls_on()
    or $RR in ('gm','admin')
    or ($RR in ('am','rm') and col not in ('settings','depts'))
    or ($RR = 'cs' and col not in ('settings','depts','regions','centers','supervisors'))
    or ($RR in ('teacher','staff') and col not in ('settings','depts','regions','centers','supervisors','books','lessons','fees','payments','tevals'))
    or ($RR in ('student','parent') and (
          (col = 'recordings' and student_id = (select public.app_student_id()))
       or (col = 'tickets' and (data->>'by') = $UU)))
  $r$;

  v_read  := replace(replace(replace(v_read,  '$RR', rr), '$UU', uu), '$CS', cs);
  v_write := replace(replace(replace(v_write, '$RR', rr), '$UU', uu), '$CS', cs);

  execute 'alter table public.docs enable row level security';
  execute 'drop policy if exists docs_v2_select on public.docs';
  execute 'drop policy if exists docs_v2_insert on public.docs';
  execute 'drop policy if exists docs_v2_update on public.docs';
  execute 'drop policy if exists docs_v2_delete on public.docs';
  execute format('create policy docs_v2_select on public.docs for select to authenticated using (%s)', v_read);
  execute format('create policy docs_v2_insert on public.docs for insert to authenticated with check (%s)', v_write);
  execute format('create policy docs_v2_update on public.docs for update to authenticated using (%s) with check (%s)', v_read, v_write);
  execute format('create policy docs_v2_delete on public.docs for delete to authenticated using ((%s) and (%s))', v_read, v_write);
end $$;

-- 4) حماية profiles: لا أحد غير المدير العام يغيّر الدور أو الربط
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me text := coalesce((select role from public.profiles where id = auth.uid()), '');
begin
  if auth.uid() is null then return new; end if;               -- عمليات الخادم (service role / دوال admin_*)
  if me in ('gm', 'admin') then return new; end if;
  if to_jsonb(new) - 'name' - 'must_change' - 'updated_at'
     is distinct from to_jsonb(old) - 'name' - 'must_change' - 'updated_at' then
    raise exception 'غير مسموح بتغيير الدور أو الربط' using errcode = '42501';
  end if;
  return new;
end; $$;
drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg before update on public.profiles
  for each row execute function public.profiles_guard();

-- 5) الدوال الحساسة: أغلقها عن anon/public (تحقق من تعريفها بعد ذلك: انظر 02c_audit.sql)
do $$
declare f text; r record;
begin
  foreach f in array array['admin_create_user','admin_reset_password','admin_set_password','admin_set_disabled'] loop
    for r in select p.oid::regprocedure as sig from pg_proc p
              join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = f loop
      execute format('revoke execute on function %s from public, anon', r.sig);
      execute format('grant execute on function %s to authenticated', r.sig);
    end loop;
  end loop;
exception when others then
  raise notice 'revoke step skipped: %', sqlerrm;
end $$;

-- =====================================================================
-- اختبار قبل التفعيل (داخل معاملة ثم تراجع، لا يبقى أي أثر):
--   begin;
--   update public.app_config set value = 'true' where key = 'rls_on';
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<UUID-المستخدم>","role":"authenticated"}';
--   select public.app_ctx();                                            -- هل الدور والنطاق صحيحان؟
--   select col, count(*) from public.docs group by col order by col;    -- قارن بما يراه فعلاً في التطبيق
--   rollback;
-- كرّر لمعلم، مشرف، مدير منطقة، طالب. ثم افتح 02b_enforce_rls.sql.
-- =====================================================================
