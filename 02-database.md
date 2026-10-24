# 2) قاعدة البيانات

## الجداول
| الجدول | الغرض |
|---|---|
| `docs` | كل بيانات التطبيق (مستند عام). أعمدة مولَّدة مفهرسة (ملف 01): `center_id, teacher_id, student_id, enrollment_id, region_id, halaqa_id, created_by_app` (من حقول JSON المقابلة). فهارس على (col) وكل عمود منها وعلى `updated_at` |
| `docs_archive` | حضور قديم منقول. RLS مفعّل بلا سياسات؛ لا يصل إليه إلا الدوال (security definer) |
| `profiles` | حساب الدخول: `id, email, role, teacher_id, center_id, student_id, name, must_change` |
| `app_config` | إعدادات خادم: `points_server`، `rls_on` وغيرها (مفتاح/قيمة نصية) |
| `auth.users` | مستخدمو Supabase Auth |

## مجموعات `docs.col`
regions، centers، halaqat، students، enrollments، teachers، supervisors، books، lessons، fees، payments، attendance، tattendance، prog، tevals، certificates، studentnotes، sessions، recordings، depts، homework، msglog، msgsched، notifications، exams، rashidiExams، editRequests، tickets، mgrades، settings.

### أشكال المستندات المهمة
- `attendance/<YYYY-MM-DD>`: `{marks:{"<studentId>":"p|l|a"}}` — حاضر/متأخر/غائب. معرّف المستند هو التاريخ.
- `prog/<studentId>`: `{rec:[{id,d,g,sessionId}], rash:[...], exams:[{d,mark,max}], adds:[{d,points}]}`؛ `g` ∈ good/vgood/excellent/redo.
- `students/<id>`: `{name,no,self_no,...}`؛ `enrollments/<id>`: `{studentId,halaqaId,teacherId,centerId,year,status:'نشط'}`.
- `settings/main`: `{currentYear, rules:{...}}` — `rules` يتجاوز قواعد النقاط الافتراضية.
- `sessions/<id>`: وثيقة الحصة `{date,teacherId,status,...}`.

## الأدوار والصلاحيات (من 02_rls_shadow.sql)
ربط الحساب بالنطاق: القيم في `profiles` (`teacher_id, student_id, center_id, region_id, dept_id`) تتغلب؛ وإن غابت يُستنتج من بريد بصيغة `u-<رقم>@...` بمطابقة `self_no` في وثائق students/teachers/supervisors (`app_ctx()`).

| الدور | القراءة | الكتابة |
|---|---|---|
| gm / admin | كل شيء | كل شيء |
| am مدير إدارة | مراكز مناطق إدارته (`dept_id`) | كل المجموعات عدا settings وdepts |
| rm مدير منطقة | مراكز منطقته | كل المجموعات عدا settings وdepts |
| cs مشرف | مركزه | عدا settings, depts, regions, centers, supervisors |
| teacher معلم | حلقاته وطلابه وتسجيلاته؛ **لا يرى fees/payments** | عدا settings, depts, regions, centers, supervisors, books, lessons, fees, payments, tevals |
| staff موظف | كل المجموعات عدا fees/payments | مثل المعلم |
| viewer عرض فقط | كل المجموعات عدا fees/payments | لا شيء |
| student / parent | بيانات طالبه فقط (تسجيلات، حضور، نقاط، واجبات، شهادات...) | تسجيلاته الصوتية وتذاكره فقط |
| pending | لا شيء (حتى settings) | لا شيء |

ملاحظات:
- `attendance` تُقرأ لكل الأدوار لأن السجل واحد لكل يوم يضم كل المراكز (لا يمكن حجبه على مستوى الصف). وهذا سبب أن `points_calc` تقرأه كاملاً.
- `tattendance` (حضور المعلمين) محجوبة عن الطالب وولي الأمر.
- التسجيلات الصوتية (`recordings`): الطالب يرى تسجيلاته، والمعلم تسجيلات طلابه (`teacher_id` أو `by`)، والأدوار الأعلى (am/rm/cs) لا ترى شيئاً؛ gm/admin وstaff/viewer يرونها عبر شرط الدور.
- دوال النطاق: `app_ctx(), app_role(), app_student_ids(), app_center_ids(), app_region_ids(), app_dept_ids(), app_enrollment_ids(), app_halaqa_ids(), app_teacher_ids()` (security definer).
- **سياسة الكتابة في 02 لا تحصر المعلم بمركزه** (يستطيع إدراج `students` في مركز آخر). الاختبار `rls_and_session.sql` يتوقع هذا الحصر، فهو إما يأتي من `02b_enforce_rls.sql` أو ثغرة؛ راجعه قبل التفعيل **[تأكيد]**.
- `profiles_guard`: لا يغيّر الدور أو الربط أحد غير gm/admin.

## RLS
سياسات على `docs` و`profiles` حسب الدور والمركز. أُدخل على مراحل: ظل (shadow) لمراقبة ما كان سيُمنع، ثم فرض (02b)، ثم تدقيق (02c). الاختبار `rls_and_session.sql` يتحقق: الطالب لا يرى غير صفوفه، المعلم لا يكتب في مركز آخر، anon لا يستدعي الدوال.

## الأداء المقاس (scale_bench.sql، 10,000 طالب × 200 يوم)
أعدّه وشغّله بعد كل تغيير في `points_calc`، وسجّل الأرقام هنا:
| القياس | الزمن (املأ) |
|---|---|
| points_many(500) | |
| halaqa_rank (حلقة 25) | |
| leaderboard(50) للكل | |
| save_session(200 طالب) — يجب < 1s | |

## ملاحظات المراجعة (أُصلحت في 03_phase2_db.sql، أكتوبر 2026)
1. `leaderboard` و`halaqa_rank`: لا تمرّر `null` (= كل الطلاب) لـ `points_calc` حين تكون القائمة المرئية فارغة.
2. `points_many(null)` مرفوضة (22023)؛ كانت تتجاوز حد 500 وتحسب للجميع.
3. `points_calc` تزيل تكرار المعرّفات؛ كان التكرار يضاعف الحضور.
4. `save_session` ترفض `p_date` غير الصالح (صيغة أو تاريخ مستحيل مثل 2026-02-31) برمز 22023.
الاختبارات المقابلة في القسم 3 و3b من `rls_and_session.sql`.
