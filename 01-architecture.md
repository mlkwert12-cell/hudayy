# 1) المعمارية

```
المتصفح (index.html + sw.js)
  ├─ GitHub Pages / (CDN مستقبلاً)      ← الملفات الثابتة
  └─ Supabase
       ├─ Auth      (بريد + كلمة مرور، توكن JWT)
       ├─ PostgREST (قراءة/كتابة جدول docs + استدعاء RPC)
       ├─ Realtime  (قناة docs-sync: postgres_changes على docs)
       └─ Postgres  (جدول docs عام + دوال + RLS)
النسخ الاحتياطي: كمبيوتر محلي يسحب pg_dump دورياً (حزمة 3.6)
المراقبة: Sentry (أخطاء/أداء) + UptimeRobot (جاهزية)
```

## نموذج البيانات «مستند عام»
كل البيانات التطبيقية في جدول واحد `docs(col, id, data jsonb, updated_at, updated_by)`؛ `col` هو اسم المجموعة (students، attendance…) و`id` المعرّف و`data` المحتوى. مزايا: مرونة الحقول. أثمانه: الفهرسة والاستعلام يعتمدان على أعمدة مولَّدة/فهارس (ملف 01) ودوال تفكّ JSON (ملف 03).

## تدفق التحميل عند فتح التطبيق (`index.html`)
1. تسجيل الدخول `signInWithPassword` ← قراءة `profiles` ← `startApp(role)`.
2. تحميل المجموعات المسموحة للدور (`colsForRole()`): الطالب وولي الأمر لا يحمّلان `supervisors, tattendance, tevals, mgrades, editRequests, msglog, msgsched`. التحميل بصفحات من 1000 صف.
3. مزامنة تزايدية بـ `docs_changed_since(p_since, p_cols)` + قناة Realtime `docs-sync`.
4. النقاط: طبقة `SP` (بين `[SP-BEGIN]` و`[SP-END]`) تسأل `points_server_enabled()`؛ إن كانت true تجمع كل طلبات `pointsOf` في طلب `points_many` واحد (حتى 500 طالب) وتخزن النتيجة. عند أي فشل ترجع للحساب المحلي وتُطفئ نفسها.
5. التخزين المحلي والعمل دون اتصال: `sw.js` (service worker) يسجَّل على https فقط.

## حفظ الحصة
الواجهة تبني الحضور والتسميع والواجب ووثيقة الحصة وترسلها في استدعاء واحد `save_session(...)` (معاملة ذرّية، SECURITY INVOKER فتُطبَّق RLS). التسميع يُدمج بقفل الصف (`for update`) فلا يضيع بسبب سباق قراءة-ثم-كتابة، والحضور يُدمج مع علامات المعلمين الآخرين لنفس اليوم عبر `merge_marks`. إعادة الإرسال آمنة (idempotent) لأن إدخالات الحصة تُحذف بـ `sessionId` ثم تُضاف.

## الأرشفة
`archive_attendance(p_before)` تنقل الحضور الأقدم من 90 يوماً إلى `docs_archive`، و`points_calc` تقرأ الجدولين فلا تتغير النقاط. لا تعمل إلا بعد تفعيل `app_config.points_server='true'`، لأن حساب النقاط في المتصفح يعتمد على الحضور المحمّل.

## ملفات المستودع
- `index.html`، `sw.js`، `manifest.webmanifest`، `icons/` — التطبيق.
- SQL بالترتيب: `01_indexes_and_rpc` ← `02_rls_shadow` ← `02b_enforce_rls` ← `02c_audit` ← `03_phase2_db`.
- الاختبارات: `rls_and_session.sql` (SQL، تفشل بـ ON_ERROR_STOP)، `points_client.js` (يختبر طبقة SP من index.html)، `scale_bench.sql` (قياس أداء 10,000 طالب × 200 يوم).
- أدوات المرحلة 3: حزم النسخ الاحتياطي، اختبار الحمل (k6)، المراقبة.
