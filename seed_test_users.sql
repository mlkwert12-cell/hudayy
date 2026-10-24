-- يُشغَّل على مشروع Supabase *تجريبي* فقط (ليس الإنتاج!). ينشئ N طالباً + حلقات + معلمين + مستخدمي دخول.
-- كلمة مرور الجميع: LoadTest#2026   البريد: stu<N>@load.test  /  tch<N>@load.test
-- غيّر n_students حسب الحاجة. يفترض وجود 01 و02 و03 وجدول profiles(id,email,role,teacher_id,center_id,student_id).
do $$
declare n_students int := 50000; per_halaqa int := 25; n_h int; n_t int; i int; uid uuid;
begin
  n_h := ceil(n_students::numeric / per_halaqa); n_t := n_h;
  insert into docs(col,id,data) values ('settings','main','{"currentYear":"2026"}') on conflict (col,id) do nothing;
  insert into docs(col,id,data) select 'centers','c'||g, '{"regionId":"r1"}' from generate_series(0,49) g on conflict do nothing;
  insert into docs(col,id,data) select 'teachers','t'||g, jsonb_build_object('centerId','c'||(g%50),'name','معلم '||g) from generate_series(1,n_t) g on conflict do nothing;
  insert into docs(col,id,data) select 'halaqat','h'||g, jsonb_build_object('centerId','c'||(g%50),'teacherId','t'||g,'name','حلقة '||g) from generate_series(1,n_h) g on conflict do nothing;
  insert into docs(col,id,data) select 'students','s'||g, jsonb_build_object('name','طالب '||g,'no',g::text) from generate_series(1,n_students) g on conflict do nothing;
  insert into docs(col,id,data) select 'enrollments','e'||g, jsonb_build_object('studentId','s'||g,'halaqaId','h'||(1+(g-1)/per_halaqa),
      'teacherId','t'||(1+(g-1)/per_halaqa),'centerId','c'||((1+(g-1)/per_halaqa)%50),'year','2026','status','نشط') from generate_series(1,n_students) g on conflict do nothing;
  -- مستخدمو الطلاب والمعلمين
  for i in 1..n_students + n_t loop
    uid := gen_random_uuid();
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,
                           created_at,updated_at,confirmation_token,recovery_token,email_change,email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000',uid,'authenticated','authenticated',
            case when i<=n_students then 'stu'||i else 'tch'||(i-n_students) end||'@load.test',
            crypt('LoadTest#2026',gen_salt('bf',4)), now(), '{"provider":"email","providers":["email"]}','{}', now(), now(),'','','','');
    insert into auth.identities(id,user_id,provider_id,identity_data,provider,created_at,updated_at,last_sign_in_at)
    select gen_random_uuid(), uid, email, jsonb_build_object('sub',uid::text,'email',email), 'email', now(), now(), now() from auth.users where id=uid;
    if i<=n_students then
      insert into profiles(id,email,role,teacher_id,center_id,student_id) select uid,email,'student',null,null,'s'||i from auth.users where id=uid;
    else
      insert into profiles(id,email,role,teacher_id,center_id,student_id) select uid,email,'teacher','t'||(i-n_students),'c'||((i-n_students)%50),null from auth.users where id=uid;
    end if;
  end loop;
  -- 60 يوم حضور تاريخي
  insert into docs(col,id,data)
   select 'attendance', to_char(current_date-d,'YYYY-MM-DD'),
          jsonb_build_object('marks',(select jsonb_object_agg('s'||g, case when random()<.7 then 'p' when random()<.5 then 'l' else 'a' end) from generate_series(1,n_students) g))
     from generate_series(1,60) d on conflict do nothing;
  analyze docs;
end $$;
