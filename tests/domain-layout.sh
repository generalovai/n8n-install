#!/usr/bin/env bash
# Русская раскладка в адресе: «nеw8nеw.ru» с русской «е» выглядит как
# настоящий, но такого адреса нет. У подписчика из-за этого скрипт сутки
# «не видел» правильную A-запись. Проверяем распознавание в двух локалях.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
S=$(grep -n '^label_kind()' "$I" | cut -d: -f1); E=$(grep -n '^mark_cyr()' "$I" | cut -d: -f1)
sed -n "${S},$((E-1))p" "$I" > "$TMP/f.sh"
cat > "$TMP/t.sh" <<'T'
. /t/f.sh; set -u
F=0; e=$(printf '\xd0\xb5'); o=$(printf '\xd0\xbe')
rf=$(printf '\xd1\x80\xd1\x84'); ru=$(printf '\xd1\x80\xd1\x83')
site=$(printf '\xd1\x81\xd0\xb0\xd0\xb9\xd1\x82')
t() { if layout_mixup "$1"; then r=ошибка; else r=норм; fi
      [ "$r" = "$2" ] || { echo "  ПРОВАЛ [$LC_ALL] $1 -> $r, ждали $2"; F=1; }; }
t "n8n.new8new.ru" норм;       t "mysite.ru" норм;     t "my-site2.ru" норм
t "123.ru" норм;               t "n8n.${site}.${rf}" норм
t "n8n.n${e}w8n${e}w.ru" ошибка; t "n8n.n${o}w8n${o}w.ru" ошибка
t "n8n.new8new.r${e}" ошибка;  t "${site}.ru" ошибка; t "site.${ru}" ошибка
exit $F
T
for loc in C C.UTF-8; do
  docker run --rm -e LC_ALL=$loc -v "$TMP:/t:ro" ubuntu:22.04 bash /t/t.sh
done
echo "  русская раскладка в адресе: 10 адресов, 2 локали, всё верно"
