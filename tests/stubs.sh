mkdir -p /stub
cat > /stub/curl <<'D'
#!/bin/bash
A="$*"
case "$A" in
  *ifconfig.me*|*ipify*)            echo "203.0.113.77";;
  *tokens/verify*)                  echo '{"success":true,"result":{"status":"active"}}';;
  *zones?name=example.ru*)          echo '{"success":true,"result":[{"id":"zone111","name":"example.ru"}]}';;
  *zones?name=*)                    echo '{"success":true,"result":[]}';;
  *dns_records?type=A*)             echo '{"success":true,"result":[]}';;
  *dns_records*)                    echo '{"success":true,"result":{"id":"rec999"}}';;
  *cloudflare.com/ips-v4*)          printf '173.245.48.0/20\n103.21.244.0/22\n';;
  *cloudflare.com/ips-v6*)          printf '2400:cb00::/32\n2606:4700::/32\n';;
  *get-docker.sh*|*get.docker.com*) echo "#!/bin/sh" > /tmp/get-docker.sh; exit 0;;
  # проверка "пускает ли прокси к Telegram": ведёт себя по TG_MODE
  *api.telegram.org/bot123/getMe*)
    case "${TG_MODE:-ok}" in
      proxy_blocked) case "$A" in *--proxy*) printf 000; exit 7;; *) printf 404;; esac;;
      both_blocked)  printf 000; exit 7;;
      *)             printf 404;;
    esac;;
  *api.telegram.org*getMe*)         echo '{"ok":true,"result":{"username":"moy_n8n_bot"}}';;
  *api.telegram.org*getUpdates*)    echo '{"ok":true,"result":[{"message":{"chat":{"id":123456789}}}]}';;
  *api.telegram.org*sendMessage*)   echo "$A" | grep -o 'text=[^&]*' | head -1 >> /tmp/tg-sent.txt; echo '{"ok":true}';;
  # сертификат "выдаётся" через CERT_WAIT секунд после первой проверки
  *https://*healthz*)
    if [ -n "${CERT_WAIT:-}" ]; then
      [ -f /tmp/cert-t0 ] || date +%s > /tmp/cert-t0
      [ $(( $(date +%s) - $(cat /tmp/cert-t0) )) -ge "$CERT_WAIT" ] || exit 22
    fi
    echo '{"status":"ok"}';;
  *healthz*)                        echo '{"status":"ok"}';;
  *api.telegram.org*)               exit 0;;
  *) exit 0;;
esac
D
cat > /stub/dig <<'D'
#!/bin/bash
# домена с "nosuch" в имени не существует; адрес с кириллицей - тоже
case "$*" in *nosuch*) exit 0;; esac
printf '%s' "$*" | LC_ALL=C grep -q '[^ -~]' && exit 0
echo "203.0.113.77"
D
cat > /stub/docker <<'D'
#!/bin/bash
case "$*" in
  *"compose version"*) echo "Docker Compose version v2.30.0";;
  *"--version"*) echo "Docker version 27.0.0, build abc";;
  *healthz*) echo '{"status":"ok"}';;
  *"api.ipify.org"*) echo "198.51.100.5";;
  *" pull "*)
    [ -n "${PULL_SLEEP:-}" ] && sleep "$PULL_SLEEP"
    case "${PULL_FAIL:-}:$*" in
      all:*) exit 1;;
      quiet:*" pull -q "*) exit 1;;
    esac;;
  *) echo "[docker] $*" >&2;;
esac
exit 0
D
cat > /stub/ufw <<'D'
#!/bin/bash
[ "$1" = status ] && echo "Status: inactive"; exit 0
D
cat > /stub/systemctl <<'D'
#!/bin/bash
exit 0
D
chmod +x /stub/*
