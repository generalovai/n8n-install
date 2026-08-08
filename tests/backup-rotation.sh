#!/usr/bin/env bash
# Проверяет, что ротация копий оставляет нужную глубину и не рвёт комплекты.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# вырезаем из установщика саму логику ротации
awk "/^cat > \"\\\$DIR\/backup.sh\" <<'EOF'\$/{on=1;next} on&&\$0==\"EOF\"{exit} on" "$ROOT/install.sh" > /tmp/bk-full.sh
python3 - <<'PY'
s = open('/tmp/bk-full.sh').read()
a = s.index('# Чем старше копия')
b = s.index('echo "Готово. Копии лежат в $OUT"')
open('/tmp/rotate.sh', 'w').write(s[a:b])
PY

docker run --rm -i -v /tmp/rotate.sh:/rotate.sh:ro ubuntu:24.04 bash -s <<'EOF'
set -u
export OUT=/tmp/b DIR=/tmp
mkdir -p $OUT
for i in $(seq 0 89); do
  d=$(date -d "-$i day" +%F)
  for p in "db-:.sql.gz" "files-:.tar.gz" "env-:.txt"; do
    pre="${p%%:*}"; ext="${p##*:}"; f="$OUT/${pre}${d}_03-00${ext}"
    echo x > "$f"; touch -d "$d 03:00" "$f"
  done
done
source /rotate.sh >/dev/null 2>&1
n=$(ls $OUT/db-*.sql.gz 2>/dev/null | wc -l)

fail=0
[ "$n" -ge 10 ] && [ "$n" -le 18 ] || { echo "  ПРОВАЛ: осталось $n копий, ждали 10-18"; fail=1; }

# все копии за последние 7 дней должны быть на месте
for i in $(seq 0 6); do
  d=$(date -d "-$i day" +%F)
  [ -f "$OUT/db-${d}_03-00.sql.gz" ] || { echo "  ПРОВАЛ: нет свежей копии за $d"; fail=1; }
done
# должна остаться хотя бы одна копия старше двух месяцев
old=$(find $OUT -name 'db-*.sql.gz' -mtime +60 | wc -l)
[ "$old" -ge 1 ] || { echo "  ПРОВАЛ: не осталось ни одной копии старше двух месяцев"; fail=1; }
# комплектность
for f in $OUT/db-*.sql.gz; do
  s=$(basename "$f" | sed 's/^db-//; s/\.sql\.gz$//')
  [ -f "$OUT/files-$s.tar.gz" ] && [ -f "$OUT/env-$s.txt" ] || { echo "  ПРОВАЛ: неполный комплект $s"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "  ротация копий: из 90 осталось $n, глубина три месяца, комплекты целые"
exit $fail
EOF
