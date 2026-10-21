-- تعيين كلمة مرور من مدير أعلى + إجبار المستخدم على تغييرها عند أول دخول
-- الصقه في Supabase ← SQL Editor ← Run (يتطلب أنك شغّلت setup.sql سابقاً)
drop function if exists public.admin_reset_password(text,text,text,text);
create function public.admin_reset_password(p_self_no text, p_new_password text, p_name text default '', p_role text default 'student')
returns text language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  lv jsonb := '{"gm":6,"am":5,"rm":4,"cs":3,"teacher":2,"student":1,"parent":1}';
  me_role text := public.app_role();
  me int := coalesce((lv->>me_role)::int, 0);
  v_email text := 'u-' || p_self_no || '@app.local';
  v_id uuid;
  v_target_role text;
  target int;
begin
  if me < 3 then raise exception 'ليست لديك صلاحية تعيين كلمات المرور'; end if;
  if length(coalesce(p_new_password,'')) < 6 then raise exception 'كلمة المرور 6 أحرف على الأقل'; end if;
  select id into v_id from auth.users where email = v_email;
  if v_id is not null then
    select role into v_target_role from public.profiles where id = v_id;
  end if;
  v_target_role := coalesce(v_target_role, p_role);
  target := coalesce((lv->>v_target_role)::int, 99);
  if me_role <> 'gm' and target >= me then raise exception 'لا يمكنك تعديل كلمة مرور مستخدم بمستوى مساوٍ أو أعلى'; end if;
  if v_id is null then
    perform public._make_user(p_self_no, p_name, v_target_role, p_new_password);
  else
    update auth.users set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
      email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_id;
  end if;
  update public.profiles set must_change = true where email = v_email;
  return 'ok';
end $$;
grant execute on function public.admin_reset_password(text,text,text,text) to authenticated;
