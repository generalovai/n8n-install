#!/usr/bin/env bash
# Прогоняет все проверки установщика в чистом контейнере Ubuntu.
# Запуск с любой машины, где есть Docker:   tests/run.sh
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== 1. Синтаксис =="
bash -n "$ROOT/install.sh" && echo "  install.sh: OK"

echo
echo "== 2. Shellcheck (установщик и все скрипты, которые он создаёт) =="
TMP="$(mktemp -d)"
cp "$ROOT/install.sh" "$TMP/"
for f in backup update restore autoupdate notify watch diagnose report; do
  awk "/^cat > \"\\\$DIR\/$f.sh\" <<'EOF'\$/{on=1;next} on&&\$0==\"EOF\"{exit} on" "$ROOT/install.sh" > "$TMP/$f.sh"
  [ -s "$TMP/$f.sh" ] || { echo "  не нашёл $f.sh в install.sh"; exit 1; }
  bash -n "$TMP/$f.sh" || exit 1
done
# в образе shellcheck нет оболочки, поэтому список файлов собираем здесь
FILES="/mnt/install.sh"
for f in backup update restore autoupdate notify watch diagnose report; do FILES="$FILES /mnt/$f.sh"; done
# shellcheck disable=SC2086
docker run --rm -e LC_ALL=C.UTF-8 -v "$TMP:/mnt" koalaman/shellcheck:stable -S warning $FILES
echo "  замечаний нет"

echo
echo "== 3. Разбор адреса прокси =="
bash "$ROOT/tests/proxy-formats.sh"

echo
echo "== 4. Ротация резервных копий =="
bash "$ROOT/tests/backup-rotation.sh"

echo
echo "== 5. Сценарии установки в Ubuntu =="
docker run --rm \
  -v "$ROOT/tests:/tests:ro" \
  -v "$ROOT/install.sh:/work/install.sh:ro" \
  ubuntu:22.04 bash /tests/scenarios.sh

echo
echo "== 6. Проверка docker-compose.yml, который генерирует установщик =="
bash "$ROOT/tests/compose-check.sh"

rm -rf "$TMP"
echo
echo "ВСЁ ПРОШЛО"
