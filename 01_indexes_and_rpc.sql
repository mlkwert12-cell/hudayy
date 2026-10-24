-- =====================================================================
-- 01_indexes_and_rpc.sql  —  آمن وإضافي (لا يغيّر سلوك التطبيق الحالي)
-- شغّله في Supabase SQL Editor. يمكن إعادة تشغيله أكثر من مرة.
-- يغطي المهام: 1.2 (فهارس) + 1.6 (حفظ دفعي) + إصلاح ضياع علامات الحضور
-- =====================================================================

-- 0) تأكد من نوع العمود data (يجب أن يكون jsonb)
--    select data_type from information_schema.columns
--     where table_name='docs' and column_name='data';
--    إن كان json وليس jsonb: alter table public.docs alter column data type jsonb using data::jsonb;

-- 1) أعمدة مولّدة من JSON (تُحسب تلقائياً) لتمكين الفهرسة والفلترة
alter table public.docs add column if not exists center_id     text generated always as (data->>'centerId')     stored;
alter table public.docs add column if not exists teacher_id    text generated always as (data->>'teacherId')    stored;
alter table public.docs add column if not exists student_id    text generated always as (data->>'studentId')    stored;
alter table public.docs add column if not exists enrollment_id text generated always as (data->>'enrollmentId') stored;
alter table public.docs add column if not exists region_id     text generated always as (data->>'regionId')     stored;
alter table public.docs add column if not exists halaqa_id     text generated always as (data->>'halaqaId')     stored;
alter table public.docs add column if not exists created_by_app text generated always as (data->>'createdBy')   stored;

-- 2) فهارس
create index if not exists docs_col_idx          on public.docs (col);
create index if not exists docs_col_center_idx   on public.docs (col, center_id);
create index if not exists docs_col_teacher_idx  on public.docs (col, teacher_id);
create index if not exists docs_col_student_idx  on public.docs (col, student_id);
create index if not exists docs_col_enroll_idx   on public.docs (col, enrollment_id);
create index if not exists docs_col_region_idx   on public.docs (col, region_id);
create index if not exists docs_col_upd_idx      on public.docs (col, updated_at desc);
create index if not exists docs_upd_idx          on public.docs (updated_at desc);
create index if not exists docs_students_name_idx
  on public.docs ((data->>'name')) where col = 'students';
analyze public.docs;

-- 3) دمج علامات الحضور بشكل ذرّي (يحل ضياع التعديلات عند حفظ عدة معلمين لنفس اليوم)
--    SECURITY INVOKER: تُطبَّق سياسات RLS الخاصة بالمستخدم.
create or replace function public.merge_marks(p_col text, p_id text, p_marks jsonb)
returns void
language plpgsql
security invoker
as $$
begin
  if p_col not in ('attendance','tattendance') then
    raise exception 'merge_marks: collection not allowed' using errcode = '22023';
  end if;
  insert into public.docs (col, id, data, updated_at, updated_by)
  values (p_col, p_id,
          jsonb_build_object('date', p_id, 'marks', coalesce(p_marks,'{}'::jsonb)),
          now(), auth.uid())
  on conflict (col, id) do update
    set data = jsonb_set(
                 coalesce(public.docs.data, '{}'::jsonb),
                 '{marks}',
                 coalesce(public.docs.data->'marks', '{}'::jsonb) || coalesce(p_marks,'{}'::jsonb),
                 true),
        updated_at = now(),
        updated_by = auth.uid();
end;
$$;
grant execute on function public.merge_marks(text,text,jsonb) to authenticated;

-- 4) رفع دفعي: صفوف كثيرة في طلب واحد. الشكل: [{"col":"..","id":"..","data":{..}}, ...]
create or replace function public.docs_upsert_many(p_rows jsonb)
returns integer
language plpgsql
security invoker
as $$
declare n integer;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'too many rows (max 500)' using errcode = '22023';
  end if;
  insert into public.docs (col, id, data, updated_at, updated_by)
  select r->>'col', r->>'id', r->'data', now(), auth.uid()
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'col','') <> '' and coalesce(r->>'id','') <> ''
  on conflict (col, id) do update
    set data = excluded.data, updated_at = now(), updated_by = auth.uid();
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.docs_upsert_many(jsonb) to authenticated;

-- 5) تحميل تزايدي: كل ما تغيّر بعد وقت معيّن (يُستخدم بدل إعادة التحميل الكامل)
create or replace function public.docs_changed_since(p_since timestamptz, p_cols text[] default null)
returns table(col text, id text, data jsonb, updated_at timestamptz)
language sql
stable
security invoker
as $$
  select d.col, d.id, d.data, d.updated_at
    from public.docs d
   where d.updated_at > p_since
     and (p_cols is null or d.col = any(p_cols))
   order by d.updated_at
   limit 5000;
$$;
grant execute on function public.docs_changed_since(timestamptz,text[]) to authenticated;

-- تحقق سريع بعد التشغيل:
--   select count(*) from pg_indexes where tablename='docs';
--   select public.docs_upsert_many('[{"col":"_test","id":"t1","data":{"x":1}}]'::jsonb);
--   delete from public.docs where col='_test';
