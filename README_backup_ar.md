# سياسة النسخ الاحتياطي (3.6)

## ما الذي يُنسخ
- مخطط `public` كاملاً: `docs` وأقسامه، `docs_archive`، `profiles`، `app_config`، والدوال والسياسات.
- `auth.users` و`auth.identities` (حتى لا يفقد المستخدمون حساباتهم عند الاستعادة).
- لا يُنسخ: ملفات التخزين (Storage) — قرار المؤسسة: التسجيلات الصوتية لا تحتاج نسخاً احتياطياً.

## طبقات الحماية
1. **Supabase**: خطة Pro تعطي نسخاً يومية تلقائية (7 أيام). Point-in-Time Recovery إضافة مدفوعة. هذه الطبقة الأولى ولا تغني عن الثانية.
2. **نسخة خارجية عندك** (هذه الحزمة): `pg_dump` يومياً إلى الكمبيوتر القديم، 14 يومية + 8 أسبوعية (~شهران). النسخ الخارجية تحميك من حذف المشروع أو خطأ الحساب.
3. **اختبار استعادة أسبوعي** آلي: نسخة غير مُختبَرة ليست نسخة.

## التركيب على الكمبيوتر القديم (Ubuntu/Debian)
```
sudo apt install postgresql-client-17 docker.io curl   # إصدار العميل >= إصدار خادم Supabase
sudo mkdir -p /opt/anwar-backup && sudo cp backup.sh restore_test.sh /opt/anwar-backup/
cp backup.env.example /opt/anwar-backup/backup.env && chmod 600 /opt/anwar-backup/backup.env
nano /opt/anwar-backup/backup.env           # ضع رابط الاتصال
/opt/anwar-backup/backup.sh                 # جرّب يدوياً أولاً
/opt/anwar-backup/restore_test.sh           # ثم جرّب الاستعادة
crontab -e                                  # الصق محتوى crontab.example
```
اضبط BIOS على «تشغيل بعد انقطاع الكهرباء»، وعطّل السكون. شفّر القرص (LUKS) لأن النسخة تحوي بيانات طلاب.

## الاستعادة الحقيقية (عند كارثة)
1. أنشئ مشروع Supabase جديداً (أو استعمل المشروع بعد تصفيره).
2. شغّل ملفات 01 و02 و03 أولاً لتجهيز الجداول/الدوال إن لزم، ثم:
   `pg_restore -d "<رابط جديد>" --no-owner --data-only --disable-triggers -t docs -t docs_archive -t profiles -t app_config <ملف.dump>`
3. استعد المستخدمين: `pg_restore ... -t auth.users -t auth.identities` (يحتاج صلاحية postgres).
4. حدّث `SUPABASE_URL` والمفتاح في التطبيق، وجرّب `select public.points_server_enabled();`.
هدف زمن الاستعادة (RTO) المقترح: أقل من ساعتين؛ نقطة الاستعادة (RPO): حتى 24 ساعة (أقل مع PITR).

## مراقبة النسخ
ضع `HEARTBEAT_URL` من خدمة مجانية (Healthchecks.io): تصلك رسالة إن لم يعمل `backup.sh` يوماً كاملاً.

## ما لم يُغطَّ
- ملفات Storage (التسجيلات الصوتية): خارج النسخ الاحتياطي بقرار المؤسسة.
- بعد اعتماد الأرشفة (`archive_attendance`) تبقى البيانات في `docs_archive` ضمن النسخة، فلا حاجة لتغيير شيء.
