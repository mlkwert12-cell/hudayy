# 3) الواجهة البرمجية (RPC)

كل الاستدعاءات عبر `supabase.rpc(name, args)` بتوكن المستخدم. الصلاحية: `authenticated` فقط (anon مسحوب منه EXECUTE).

## الحفظ
### `save_session(p_session_id, p_session, p_date, p_marks, p_prog, p_homework) → {ok, marks, prog, homework}`
- معاملة واحدة، SECURITY INVOKER (RLS يُطبَّق).
- `p_marks`: `{"<sid>":"p|l|a"}` يُدمج مع علامات اليوم. `p_prog`: `{"<sid>":{"rec":[...],"rash":[...]}}` يحذف إدخالات `sessionId` نفسها ثم يضيف الجديدة. `p_homework`: وثيقة واجب لكل طالب. ثم وثيقة الحصة آخراً.
- حدود: ≤ 500 طالب في `p_prog`، ≤ 2000 في `p_marks`. أخطاء: 22023 بيانات ناقصة/كبيرة.
- آمن لإعادة الإرسال.

## النقاط
| الدالة | الإدخال | الإخراج |
|---|---|---|
| `points_many(p_sids text[], p_from, p_to)` | ≤ 500 معرّف، نطاق تاريخ اختياري `YYYY-MM-DD` | `{"<sid>":{att,rec,exam,add,streak,p,l,a,nRec,nExam,nAdd,total}}`؛ الطلاب خارج النطاق يُتجاهلون |
| `student_points(p_sid, p_from, p_to)` | طالب واحد | الكائن نفسه؛ 42501 إن لم يُسمح |
| `halaqa_rank(p_sid, p_from, p_to, p_year)` | | `{rank, of, total}` بلا أسماء الزملاء |
| `leaderboard(p_from,p_to,p_year,p_halaqa,p_limit≤500)` | | جدول مرتّب بالنقاط (ضمن نطاق المستخدم) |
| `points_server_enabled()` | | boolean من `app_config.points_server` |
| `points_rules()` | | القواعد الافتراضية مدموجة مع `settings/main.rules` |

### معادلة النقاط (تطابق `pointsOf` في الواجهة)
- **الحضور**: حاضر +1، متأخر −2، غائب −2 (قابلة للتعديل في `rules`).
- **التسميع**: مجموع قيمة التقدير: جيد +1، جيد جداً +2، ممتاز +3، إعادة −3.
- **الاختبارات**: `floor(mark/max*100*examFactor + 0.5)` (max=0 تعني 100).
- **الإضافات**: مجموع `adds[].points`.
- **المواظبة**: لكل `streakDays` (15) حصة حاضر متتالية +`streakBonus` (15). تنكسر بأي يوم غير حاضر أو بلا علامة.
- المدى الزمني يُطبَّق على كل المكونات إذا حُدّد.

## الأرشفة
- `archive_attendance(p_before text) → عدد` : gm/admin فقط؛ يشترط `points_server=true` وأن يكون التاريخ أقدم من 90 يوماً.
- `restore_attendance(p_from, p_to) → عدد` : يعيد من الأرشيف.

## دوال البيانات العامة (01_indexes_and_rpc.sql) — SECURITY INVOKER (يُطبَّق RLS)
- `merge_marks(p_col text, p_id text, p_marks jsonb) → void`: دمج ذرّي لعلامات `attendance` أو `tattendance` ليوم `p_id` (غير ذلك يرفض 22023).
- `docs_upsert_many(p_rows jsonb) → int`: رفع دفعي `[{"col","id","data"}]`، الحد 500 صف، يتجاهل الصفوف بلا col/id.
- `docs_changed_since(p_since timestamptz, p_cols text[]) → (col,id,data,updated_at)`: التحميل التزايدي، مرتّب بـ `updated_at`، **الحد 5000 صف** — إن أعاد 5000 فاستدعِ ثانية من آخر `updated_at`.
- دوال إدارة الحسابات (`admin_create_user, admin_reset_password, admin_set_password, admin_set_disabled`) و`create_profile`: تعريفها خارج الملفات المرفقة؛ مسحوب EXECUTE منها من anon بواسطة 02، ومراجعتها في `02c_audit` **[تأكيد التواقيع]**.

## دوال داخلية (غير مكشوفة للعميل)
`points_calc` (الحساب الأساسي)، `_num`، `_can_see_student`، `jsonb_object_keys_count` — مسحوب EXECUTE من anon، و`points_calc` مسحوب من authenticated أيضاً.

## رموز الأخطاء
22023 مدخل غير صالح · 42501 غير مسموح · 55000 شرط مسبق غير متحقق (الأرشفة قبل تفعيل النقاط من الخادم).
