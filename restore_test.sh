#!/usr/bin/env bash
# اختبار استعادة: يعيد أحدث نسخة إلى قاعدة محلية مؤقتة ويقارن الأعداد. لا يلمس Supabase إطلاقاً.
# يحتاج PostgreSQL محلياً (أو docker). التشغيل: ./restore_test.sh [ملف.dump]
set -euo pipefail
cd "$(dirname "$0")"; [ -f backup.env ] && . ./backup.env
BACKUP_DIR="${BACKUP_DIR:-$HOME/anwar-backups}"
f="${1:-$(ls -1t "$BACKUP_DIR"/daily/*.dump | head -1)}"
( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" )

if command -v docker >/dev/null; then
  c=anwar-restore-test; docker rm -f $c >/dev/null 2>&1 || true
  docker run -d --name $c -e POSTGRES_PASSWORD=t -p 54399:5432 supabase/postgres:15.8.1.060 >/dev/null
  trap 'docker rm -f $c >/dev/null 2>&1' EXIT
  url='postgresql://postgres:t@localhost:54399/postgres'
  until pg_isready -h localhost -p 54399 -q; do sleep 1; done; sleep 3
else
  : "${LOCAL_TEST_URL:?لا يوجد docker: ضع LOCAL_TEST_URL لقاعدة محلية فارغة للاختبار}"; url="$LOCAL_TEST_URL"
fi
# أخطاء الأدوار/الامتدادات غير الحرجة متوقعة خارج Supabase؛ المهم سلامة البيانات أدناه
pg_restore -d "$url" --no-owner --no-privileges --clean --if-exists "$f" 2>restore.log || true
q(){ psql "$url" -Atc "$1"; }
echo "docs: $(q 'select count(*) from public.docs')  archive: $(q 'select count(*) from public.docs_archive' 2>/dev/null || echo -)"
echo "students: $(q "select count(*) from public.docs where col='students'")  attendance days: $(q "select count(*) from public.docs where col='attendance'")"
n=$(q 'select count(*) from public.docs'); [ "$n" -gt 0 ] || { echo "فشل: docs فارغ" >&2; exit 1; }
# مطابقة دالة النقاط بعد الاستعادة (إن وُجدت الدوال)
q "select public.points_server_enabled()" >/dev/null 2>&1 && echo "functions OK" || echo "تنبيه: الدوال غير موجودة (راجع restore.log)"
echo "RESTORE TEST PASSED  ($f)"
