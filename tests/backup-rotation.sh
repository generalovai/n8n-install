#!/usr/bin/env bash
# Проверяет ротацию копий: глубину архива, свежую неделю и комплектность.
# Глубину считаем по датам в именах файлов, а не по времени изменения -
# иначе проверка зависела бы от того, в какой день её запустили.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

awk "/^cat > \"\\\$DIR\/backup.sh\" <<'EOF'\$/{on=1;next} on&&\$0==\"EOF\"{exit} on" "$ROOT/install.sh" > /tmp/bk-full.sh
python3 - <<'PY'
s = open('/tmp/bk-full.sh').read()
a = s.index('# Чем старше копия')
b = s.index('echo "Готово. Копии лежат в $OUT"')
open('/tmp/rotate.sh', 'w').write(s[a:b])
PY

docker run --rm -i -v /tmp/rotate.sh:/rotate.sh:ro ubuntu:24.04 bash -s <<'EOF'
set -u
export DIR=/tmp
fail=0
# гоняем на разных днях недели и месяца: ротация не должна от них зависеть
for back in 0 1 3 5 10 17 24; do
  export OUT=/tmp/b$back; rm -rf $OUT; mkdir -p $OUT
  today=$(date -d "-$back day" +%F)
  for i in $(seq 0 200); do
    d=$(date -d "$today -$i day" +%F)
    for p in "db-:.sql.gz" "files-:.tar.gz" "env-:.txt"; do
      pre="${p%%:*}"; ext="${p##*:}"; f="$OUT/${pre}${d}_03-00${ext}"
      echo x > "$f"; touch -d "$d 03:00" "$f"
    done
  done
  source /rotate.sh >/dev/null 2>&1

  n=$(ls $OUT/db-*.sql.gz 2>/dev/null | wc -l)
  [ "$n" -ge 12 ] && [ "$n" -le 26 ] || { echo "  ПРОВАЛ ($today): осталось $n копий, ждали 12-26"; fail=1; }

  # вся свежая неделя на месте
  for i in $(seq 0 6); do
    d=$(date -d "$today -$i day" +%F)
    [ -f "$OUT/db-${d}_03-00.sql.gz" ] || { echo "  ПРОВАЛ ($today): нет свежей копии за $d"; fail=1; }
  done

  # глубина архива - не меньше ста дней
  oldest=$(ls -1t $OUT/db-*.sql.gz | tail -1 | sed 's|.*/db-||; s|_03-00.sql.gz||')
  depth=$(( ( $(date -d "$today" +%s) - $(date -d "$oldest" +%s) ) / 86400 ))
  [ "$depth" -ge 100 ] || { echo "  ПРОВАЛ ($today): архив всего на $depth дней, ждали от 100"; fail=1; }

  # комплектность: у копии базы есть файлы и настройки
  for f in $OUT/db-*.sql.gz; do
    s=$(basename "$f" | sed 's/^db-//; s/\.sql\.gz$//')
    [ -f "$OUT/files-$s.tar.gz" ] && [ -f "$OUT/env-$s.txt" ] || { echo "  ПРОВАЛ: неполный комплект $s"; fail=1; }
  done
done

[ "$fail" -eq 0 ] && echo "  ротация копий: проверено на 7 разных датах, глубина от 100 дней, комплекты целые"
exit $fail
EOF
