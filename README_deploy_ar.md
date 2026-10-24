# ما يُرفع ولماذا يعمل التطبيق بعده

## 0) قبل أي شيء
خذ نسخة احتياطية: Supabase > Database > Backups، أو `backup.sh` من حزمة 3.6. نفّذ SQL **خارج أوقات الحصص**.

## 1) قاعدة البيانات (Supabase > SQL Editor، بهذا الترتيب، كل ملف مرة واحدة ويمكن إعادته)
| # | الملف | الأثر |
|---|---|---|
| 1 | `sql/01_indexes_and_rpc.sql` | فهارس + `merge_marks` + `docs_upsert_many` + `docs_changed_since` |
| 2 | `sql/02_rls_shadow.sql` (**مصحَّح**) | سياسات RLS في وضع الظل: لا تغيّر السلوك لأن `rls_on='false'` |
| 3 | `sql/03_phase2_db.sql` (**مصحَّح**) | `save_session` + دوال النقاط + الأرشفة. لا تغيّر السلوك حتى تفعّل `points_server` |

تحقق بعد التشغيل:
```sql
select count(*) from pg_policy where polrelid='public.docs'::regclass;   -- يجب 4
select public.points_server_enabled();                                    -- false
select public.docs_upsert_many('[{"col":"_test","id":"t1","data":{"x":1}}]'::jsonb);
delete from public.docs where col='_test';
```
> إن كنت شغّلت نسخة `02` القديمة سابقاً فأعد تشغيل المصحَّحة (آمنة لإعادة التشغيل).
> **لا تشغّل** `02b_enforce_rls` الآن: لم أراجعه بعد (انظر الرد)، وهو تفعيل الفرض.

## 2) الواجهة (GitHub Pages)
1. ارفع `site/index.html` مكان `index.html` الحالي (يحوي طبقة النقاط من الخادم SP، وهي تعمل محلياً حتى تُفعَّل).
2. ارفع رقم نسخة الـ cache في `sw.js` (عندك) كي يتحدّث التخزين عند المستخدمين.
3. لا حاجة لتغيير `sw.js`/`manifest`/`icons` غير ذلك.

## 3) تفعيل النقاط من الخادم (اختياري، بعد التأكد أن 1 و2 و3 يعملان)
```sql
insert into app_config(key,value) values ('points_server','true')
  on conflict (key) do update set value='true';
```
للتراجع: القيمة `'false'`. **الأرشفة (`archive_attendance`) لا تُشغَّل قبل هذه الخطوة.**

## 4) اختياري
- المراقبة: حزمة 3.4 (تحتاج DSN).
- لا شيء آخر مطلوب لتشغيل التطبيق؛ النسخ الاحتياطي واختبار الحمل أدوات منفصلة تعمل خارج الموقع.
