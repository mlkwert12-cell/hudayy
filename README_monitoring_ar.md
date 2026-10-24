# المراقبة (3.4)

## التركيب (10 دقائق)
1. أنشئ حساباً مجانياً في sentry.io ← مشروع من نوع **Browser JavaScript** ← انسخ **DSN**.
2. افتح `monitoring_snippet.html` وضع الـ DSN في `dsn:''`، وغيّر `release` مع كل إصدار.
3. `python3 apply_monitoring.py index.html index_monitored.html` ثم ارفع الملف الناتج كـ `index.html`.
   (الأداة تدرج المقطع في `<head>`، وتضيف `Mon.user(S.profile)` داخل `startApp`، ولا تعدّل الأصل.)
4. افتح التطبيق وشغّل في الكونسول `throw new Error('اختبار Sentry')` — يجب أن يظهر الخطأ في Sentry خلال دقيقة.

## الخصوصية (طلاب وقاصرون)
- يُرسل **معرّف المستخدم والدور فقط**؛ لا اسم ولا بريد (`sendDefaultPii:false`).
- تسجيل الجلسة (Replay) **عند حدوث خطأ فقط**، مع إخفاء كل النصوص والحقول والوسائط. لا تسجيل عشوائي.
- بدّل LogRocket بـ Replay المدمج في Sentry: أرخص وأسهل في الإخفاء. إن أصررت على LogRocket فعطّل Replay هنا وأخبرني.
- حمّل Sentry بعد 1.5 ثانية من اكتمال الصفحة، فلا يؤثر على زمن الفتح. حجم الحزمة ~100KB مضغوطة.

## قواعد التنبيه (Alerts > Create Alert في Sentry)
| التنبيه | الشرط | القناة |
|---|---|---|
| خطأ جديد | أي issue جديد في production | بريد فوري |
| ارتفاع مفاجئ | أكثر من 50 حدثاً خلال 10 دقائق | بريد/تيليغرام |
| تراجع الإصدار | issue كان محلولاً وعاد | بريد |
| الأداء | LCP p75 > 4s أو INP p75 > 500ms | بريد أسبوعي |
تقارير الأداء الدورية: فعّل **Weekly Reports** في Settings > Notifications.

## مراقبة الجاهزية (مجاناً)
- **UptimeRobot / Better Stack**: افحص كل 5 دقائق رابط التطبيق على GitHub Pages، ورابط `https://<ref>.supabase.co/auth/v1/health` (يحتاج ترويسة apikey) أو `rest/v1/` بالمفتاح العام.
- **Supabase > Reports**: راقب CPU وعدد الاتصالات والذاكرة؛ ثبّت تنبيه بريد عند CPU > 80% (Project Settings > Notifications إن توفر في خطتك).
- أضف رابط نبض النسخ الاحتياطي (من حزمة 3.6) في نفس لوحة Healthchecks.

## أحداث مهمة يُنصح بإرسالها (اختياري، سطر واحد لكل موضع)
```js
Mon.event('save_session failed', {code: err.code}, 'error');      // في catch حفظ الحصة
Mon.event('points server fallback to local', {}, 'warning');      // عندما يعود SP للحساب المحلي
Mon.time('save_session_ms', Date.now()-t0);                        // قياس زمن الحفظ الفعلي عند المستخدمين
```
قياس `save_session_ms` الحقيقي أهم من اختبار الحمل لأنه من شبكات المستخدمين فعلاً.

## الحدود
- الخطة المجانية: 5,000 خطأ/شهر. مع 10,000 مستخدم قد تتجاوزها عند انتشار خطأ واحد؛ لهذا فلتر `IGNORE` يستبعد أخطاء الشبكة الشائعة، وخفّض `tracesSampleRate` إن اقتربت من الحد.
- لم أثبّت `integrity` (SRI) للسكربت لأنني لم أتمكن من جلب الـ hash هنا؛ إن أردته، احسبه من الملف المنشور على CDN وأضفه.
