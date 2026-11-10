#!/usr/bin/env bash
# Автообновление не должно само перескакивать на новую большую версию n8n
# (2.x -> 3.x): там убирают ноды, и воркфлоу могут тихо перестать работать.
# Docker заменён заглушкой, которая помнит, какой образ под каким именем.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
awk "/^cat > \"\\\$DIR\/autoupdate.sh\" <<'EOF'\$/{on=1;next} on&&\$0==\"EOF\"{exit} on" "$ROOT/install.sh" > "$TMP/autoupdate.sh"
[ -s "$TMP/autoupdate.sh" ] || { echo "  не нашёл autoupdate.sh в install.sh"; exit 1; }

cat > "$TMP/docker" <<'D'
#!/bin/bash
S=/tmp/dk; key() { printf '%s' "$1" | tr '/:' '__'; }
idof() { if [ -f "$S/tag_$(key "$1")" ]; then cat "$S/tag_$(key "$1")"; elif [ -f "$S/ver_$1" ]; then echo "$1"; else return 1; fi; }
last="${*: -1}"
case "$1" in
  image)
    case "$*" in
      *prune*) ;;
      *image.version*) id="$(idof "$last")" || exit 1; cat "$S/ver_$id" ;;
      *.Id*) idof "$last" || exit 1 ;;
    esac ;;
  pull) cat "$S/registry" > "$S/tag_$(key "$last")" ;;
  tag)  id="$(idof "$2")" || exit 1; echo "$id" > "$S/tag_$(key "$3")" ;;
  rmi)  rm -f "$S/tag_$(key "$2")" ;;
  compose)
    case "$*" in
      *"n8n --version"*) cat "$S/running" ;;
      *healthz*) echo '{"status":"ok"}' ;;
      *" up "*) id="$(idof docker.n8n.io/n8nio/n8n:latest)"; cat "$S/ver_$id" > "$S/running"; echo up >> "$S/ups" ;;
    esac ;;
esac
exit 0
D

cat > "$TMP/t.sh" <<'T'
set -u
export PATH=/usr/local/stub:$PATH
mkdir -p /usr/local/stub /opt/n8n/backups; cp /t/docker /usr/local/stub/docker; chmod +x /usr/local/stub/docker
cp /t/autoupdate.sh /opt/n8n/autoupdate.sh; chmod +x /opt/n8n/autoupdate.sh
printf '#!/bin/sh\necho "$1" >> /tmp/sent\n' > /opt/n8n/notify.sh
printf '#!/bin/sh\ntouch /opt/n8n/backups/db-x.sql.gz\n' > /opt/n8n/backup.sh
chmod +x /opt/n8n/notify.sh /opt/n8n/backup.sh
F=0
ok()  { echo "  ок      $1"; }
bad() { echo "  ПРОВАЛ  $1"; F=1; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
setup() {  # setup ВЕРСИЯ_СЕЙЧАС ВЕРСИЯ_В_РЕЕСТРЕ
  rm -rf /tmp/dk /tmp/sent /opt/n8n/.major-notified-* /opt/n8n/ОБНОВЛЕНИЕ*; mkdir -p /tmp/dk
  echo "N8N_IMAGE_TAG=latest" > /opt/n8n/.env
  echo "$1" > /tmp/dk/ver_old; echo "$2" > /tmp/dk/ver_new
  echo old > /tmp/dk/tag_docker.n8n.io_n8nio_n8n_latest
  echo new > /tmp/dk/registry; echo "$1" > /tmp/dk/running
}
latest() { cat /tmp/dk/tag_docker.n8n.io_n8nio_n8n_latest; }
ups()    { cat /tmp/dk/ups 2>/dev/null | wc -l; }

echo "  -- мелкое обновление 2.46.7 -> 2.47.0"
setup 2.46.7 2.47.0; /opt/n8n/autoupdate.sh >/dev/null 2>&1
chk "обновилось само"                     '[ "$(cat /tmp/dk/running)" = 2.47.0 ]'
chk "пришло «n8n обновлён»"                'grep -q "n8n обновлён" /tmp/sent'

echo "  -- большое обновление 2.46.7 -> 3.1.0, ночью"
setup 2.46.7 3.1.0; /opt/n8n/autoupdate.sh >/dev/null 2>&1
chk "само не обновилось"                   '[ "$(cat /tmp/dk/running)" = 2.46.7 ] && [ "$(ups)" -eq 0 ]'
chk "прежний образ остался под latest"     '[ "$(latest)" = old ]'
chk "пришло «Вышел n8n 3»"                 'grep -q "Вышел n8n 3" /tmp/sent'
/opt/n8n/autoupdate.sh >/dev/null 2>&1
chk "вторую ночь не повторяет сообщение"   '[ "$(grep -c "Вышел n8n 3" /tmp/sent)" -eq 1 ]'
chk "вторую ночь тоже не обновилось"       '[ "$(cat /tmp/dk/running)" = 2.46.7 ]'

echo "  -- человек сам запускает update.sh (без терминала - без вопроса)"
/opt/n8n/autoupdate.sh --force </dev/null >/dev/null 2>&1
chk "обновилось на 3.1.0"                  '[ "$(cat /tmp/dk/running)" = 3.1.0 ]'
chk "отметка «сообщили» убрана"            '! ls /opt/n8n/.major-notified-* >/dev/null 2>&1'

echo "  -- update.sh в терминале: спрашивает перед большим обновлением"
setup 2.46.7 3.1.0
printf 'n\n' | script -qec "/opt/n8n/autoupdate.sh --force" /dev/null > /tmp/tty.out 2>&1
chk "спросил «Обновляться?»"               'grep -q "Обновляться?" /tmp/tty.out'
chk "ответ n - осталась прежняя"            '[ "$(cat /tmp/dk/running)" = 2.46.7 ] && [ "$(latest)" = old ]'
printf 'y\n' | script -qec "/opt/n8n/autoupdate.sh --force" /dev/null > /tmp/tty.out 2>&1
chk "ответ y - обновилось"                  '[ "$(cat /tmp/dk/running)" = 3.1.0 ]'

echo "  -- версия неизвестна (n8n не запущен) - берём из образа"
setup 2.46.7 3.1.0; : > /tmp/dk/running; /opt/n8n/autoupdate.sh >/dev/null 2>&1
chk "всё равно не перескочил"              '[ "$(ups)" -eq 0 ] && [ "$(latest)" = old ]'
exit $F
T
docker run --rm -e LC_ALL=C.UTF-8 -v "$TMP:/t:ro" ubuntu:22.04 bash /t/t.sh
echo "  автообновление: большие версии сами не ставятся, мелкие - ставятся"
