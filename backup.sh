#!/usr/bin/env bash
# نسخ احتياطي منطقي لقاعدة Supabase: مخطط public كاملاً (بما فيه docs_archive) + مستخدمو auth.
# التشغيل: ./backup.sh   (يقرأ backup.env بجانبه)
set -euo pipefail
cd "$(dirname "$0")"
[ -f backup.env ] && . ./backup.env
: "${SUPABASE_DB_URL:?ضع SUPABASE_DB_URL في backup.env}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/anwar-backups}"; KEEP_DAILY="${KEEP_DAILY:-14}"; KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
mkdir -p "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly"
ts=$(date -u +%Y%m%dT%H%M%SZ); out="$BACKUP_DIR/daily/anwar_$ts.dump"; tmp="$out.partial"
trap 'rm -f "$tmp"' EXIT

# -Fc: صيغة مضغوطة تدعم الاستعادة الانتقائية. نستثني مخططات Supabase الداخلية ونأخذ auth.users فقط.
pg_dump "$SUPABASE_DB_URL" -Fc --no-owner --no-privileges \
  --schema=public --table='auth.users' --table='auth.identities' \
  -f "$tmp"

# تحقق أن الملف قابل للقراءة وفيه جدول docs قبل اعتماده
pg_restore -l "$tmp" | grep -q 'TABLE DATA public docs' || { echo "النسخة لا تحتوي docs!" >&2; exit 1; }
mv "$tmp" "$out"; trap - EXIT
( cd "$BACKUP_DIR/daily" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

# نسخة أسبوعية كل أحد
[ "$(date -u +%u)" = 7 ] && cp "$out" "$out.sha256" "$BACKUP_DIR/weekly/"

# تدوير
prune(){ ls -1t "$1"/*.dump 2>/dev/null | tail -n +"$(( $2 + 1 ))" | while read -r f; do rm -f "$f" "$f.sha256"; done; }
prune "$BACKUP_DIR/daily" "$KEEP_DAILY"; prune "$BACKUP_DIR/weekly" "$KEEP_WEEKLY"

echo "OK $out ($(du -h "$out" | cut -f1))"
[ -n "${HEARTBEAT_URL:-}" ] && curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null || true
