-- حلقات أنوار الهداية — إعداد Supabase (شغّله مرة واحدة: SQL Editor ← New query ← الصق ← Run)

-- 1) المستخدمون وصلاحياتهم
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'pending' check (role in ('pending','viewer','staff','admin')),
  created_at timestamptz not null default now()
);

-- 2) كل بيانات التطبيق (طلاب، تسجيلات، رسوم، ...) في جدول واحد
create table if not exists public.docs (
  col text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (col, id)
);

alter table public.profiles enable row level security;
alter table public.docs enable row level security;

-- دالة تعيد صلاحية المستخدم الحالي
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profiles where id = auth.uid()), 'pending')
$$;

-- أول مستخدم يسجّل يصبح مشرفاً مسؤولاً، والبقية «بانتظار الموافقة» ولا يرون شيئاً
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, case when exists (select 1 from public.profiles) then 'pending' else 'admin' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- سياسات profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'admin');
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- سياسات docs
-- القراءة: عرض/موظف/مشرف. الكتابة: الموظف على كل شيء عدا (المعلمون، المشرفون، المراكز، الحلقات، الإعدادات) فهي للمشرف المسؤول فقط.
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated
  using (public.my_role() in ('viewer','staff','admin'));

drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated
  with check (public.my_role() = 'admin'
    or (public.my_role() = 'staff' and col not in ('teachers','supervisors','centers','halaqat','settings')));

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated
  using (public.my_role() = 'admin'
    or (public.my_role() = 'staff' and col not in ('teachers','supervisors','centers','halaqat','settings')))
  with check (public.my_role() = 'admin'
    or (public.my_role() = 'staff' and col not in ('teachers','supervisors','centers','halaqat','settings')));

drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated
  using (public.my_role() = 'admin'
    or (public.my_role() = 'staff' and col not in ('teachers','supervisors','centers','halaqat','settings')));

-- منع الزائر غير المسجّل نهائياً
revoke all on public.docs from anon;
revoke all on public.profiles from anon;

-- 3) التحديث الفوري بين الأجهزة
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;
