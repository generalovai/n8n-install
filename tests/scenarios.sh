#!/usr/bin/env bash
# Сценарии установки. Запуск: tests/run.sh (в контейнере Ubuntu).
bash "$(dirname "$0")/stubs.sh"; export PATH=/stub:$PATH
FAILED=0
run() {
  printf "%-52s" "$1"; shift
  printf "$1" | bash "${INSTALL_SH:-/work/install.sh}" >/tmp/r.log 2>&1
  c=$?; e=$(grep -c 'ОШИБКА' /tmp/r.log)
  if [ "$c" -eq 0 ] && [ "$e" -eq 0 ]; then
    echo "OK"
  else
    echo "ПРОВАЛ код=$c ошибок=$e"; tail -8 /tmp/r.log; FAILED=1
  fi
}
rm -rf /opt/n8n; run "А: обычный домен, без прокси"            'n8n.mysite.ru\nн\nн\nadmin@m.ru\nEurope/Moscow\nд\nн\n'
             run "А2: повторный запуск"                        'д\nн\nд\nadmin@m.ru\nEurope/Moscow\nн\n'
rm -rf /opt/n8n; run "Б: Cloudflare + socks5 + оранжевое"      'n8n.example.ru\nд\nsocks5://u:secret@1.2.3.4:1080\nд\nfaketoken123\nд\nadmin@e.ru\nEurope/Moscow\nд\nн\n'
             run "Б2: повторный запуск"                        'д\nн\nд\nadmin@e.ru\nEurope/Moscow\nн\n'
rm -rf /opt/n8n; run "В: обычный домен + http-прокси"          'n8n.mysite.ru\nд\nhttp://u:p@10.0.0.1:3128\nн\nadmin@m.ru\nEurope/Moscow\nд\nн\n'
rm -rf /opt/n8n; run "Г: Cloudflare без прокси, серое облако"  'n8n.example.ru\nн\nд\nfaketoken123\nн\nadmin@e.ru\nEurope/Moscow\nд\nн\n'
rm -rf /opt/n8n; run "Д: домен без поддомена"                  'mysite.ru\nн\nн\nadmin@m.ru\nEurope/Moscow\nд\nн\n'
rm -rf /opt/n8n; run "Е: пароль прокси с долларом"             'n8n.mysite.ru\nд\nsocks5://u:pa$w0rd@1.2.3.4:1080\nн\nadmin@m.ru\nEurope/Moscow\nд\nн\n'

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "ЕСТЬ ПРОВАЛИВШИЕСЯ СЦЕНАРИИ"
  exit 1
fi
echo
echo "все сценарии прошли"
