-- قياس أداء دوال النقاط على بيانات بحجم 10,000 طالب × 200 يوم حصة. على قاعدة تجريبية فقط.
\timing on
delete from docs;
insert into docs(col,id,data)
 select 'attendance', to_char(date '2026-01-01' + d, 'YYYY-MM-DD'),
        jsonb_build_object('marks', (select jsonb_object_agg('s'||g, case when random()<.7 then 'p' when random()<.5 then 'l' else 'a' end) from generate_series(1,10000) g))
   from generate_series(0,199) d;
insert into docs(col,id,data)
 select 'prog', 's'||g, jsonb_build_object('rec', (select jsonb_agg(jsonb_build_object('id',k,'d',to_char(date '2026-01-01'+(k%200),'YYYY-MM-DD'),'g','good')) from generate_series(1,40) k), 'exams','[]','adds','[]')
   from generate_series(1,10000) g;
insert into docs(col,id,data) select 'students','s'||g, jsonb_build_object('name','طالب '||g,'no',g::text) from generate_series(1,10000) g;
insert into docs(col,id,data) select 'enrollments','e'||g, jsonb_build_object('studentId','s'||g,'halaqaId','h'||(g%400),'year','2026','status','نشط','centerId','c'||(g%40)) from generate_series(1,10000) g;
insert into docs(col,id,data) values ('settings','main','{"currentYear":"2026"}');
analyze docs;
\echo --- points_many(500 طالب)  [الاستدعاء الدفعي من الواجهة]
select jsonb_object_keys_count(public.points_many((select array_agg('s'||g) from generate_series(1,500) g))) ;
\echo --- halaqa_rank (حلقة 25 طالباً)
select public.halaqa_rank('s7');
\echo --- leaderboard(50) لكل الـ10,000
select count(*) from public.leaderboard(null,null,null,null,50);
\echo --- points_many(500) خلال آخر 30 يوماً فقط
select jsonb_object_keys_count(public.points_many((select array_agg('s'||g) from generate_series(1,500) g),'2026-06-01','2026-07-15'));
