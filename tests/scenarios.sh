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
rm -rf /opt/n8n; run "А: обычный домен, без прокси"            'n8n.mysite.ru\nn\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
             run "А2: повторный запуск"                        'y\nn\ny\nadmin@m.ru\nEurope/Moscow\nn\n'
rm -rf /opt/n8n; run "Б: Cloudflare + socks5 + оранжевое"      'n8n.example.ru\ny\nsocks5://u:secret@1.2.3.4:1080\ny\ny\nfaketoken123\ny\nadmin@e.ru\nEurope/Moscow\ny\nn\n'
             # у сценария Б сохранён прокси: второй ответ - "оставить его"
             run "Б2: повторный запуск"                        'y\ny\ny\nadmin@e.ru\nEurope/Moscow\nn\n'
rm -rf /opt/n8n; run "В: обычный домен + http-прокси"          'n8n.mysite.ru\ny\nhttp://u:p@10.0.0.1:3128\ny\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
rm -rf /opt/n8n; run "Г: Cloudflare без прокси, серое облако"  'n8n.example.ru\nn\ny\nfaketoken123\nn\nadmin@e.ru\nEurope/Moscow\ny\nn\n'
rm -rf /opt/n8n; run "Д: домен без поддомена"                  'mysite.ru\nn\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
rm -rf /opt/n8n; run "Е: пароль прокси с долларом"             'n8n.mysite.ru\ny\nsocks5://u:pa$w0rd@1.2.3.4:1080\ny\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'

# --- прокси, который закрывает Telegram ---------------------------------------
check() {  # check "что проверяем" команда...
  printf "%-52s" "$1"; shift
  if "$@" >/dev/null 2>&1; then echo "OK"; else echo "ПРОВАЛ"; FAILED=1; fi
}
HTTP_PROXY_ANS='n8n.mysite.ru\ny\nhttp://u:p@10.0.0.1:3128\ny\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
rm -rf /opt/n8n; export TG_MODE=proxy_blocked
             run "Ж: прокси закрывает Telegram, напрямую можно"  "$HTTP_PROXY_ANS"
             check "Ж: Telegram выведен из-под прокси (.env)"    grep -q '^NO_PROXY_EXTRA=,api.telegram.org,.telegram.org' /opt/n8n/.env
             check "Ж: об этом сказано человеку"                 grep -q 'не пускает к Telegram' /tmp/r.log
export TG_MODE=both_blocked
             run "Ж2: повторный запуск, Telegram не виден нигде" 'y\ny\ny\nadmin@m.ru\nEurope/Moscow\nn\n'
             check "Ж2: прежнее решение сохранилось"             grep -q '^NO_PROXY_EXTRA=,api.telegram.org' /opt/n8n/.env
             check "Ж2: человека предупредили"                   grep -q 'ни через прокси, ни напрямую' /tmp/r.log
rm -rf /opt/n8n
             run "Ж3: Telegram закрыт везде, установка идёт"     "$HTTP_PROXY_ANS"
             check "Ж3: исключения нет"                          grep -q '^NO_PROXY_EXTRA=$' /opt/n8n/.env
export TG_MODE=ok
rm -rf /opt/n8n; run "Ж4: прокси пускает Telegram"               "$HTTP_PROXY_ANS"
             check "Ж4: исключения нет"                          grep -q '^NO_PROXY_EXTRA=$' /opt/n8n/.env
rm -rf /opt/n8n; run "Ж5: без прокси"                            'n8n.mysite.ru\nn\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
             check "Ж5: исключения нет"                          grep -q '^NO_PROXY_EXTRA=$' /opt/n8n/.env

# --- долгие шаги пишут, что работа идёт ----------------------------------------
PLAIN_ANS='n8n.mysite.ru\nn\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
rm -rf /opt/n8n; export PULL_SLEEP=20
             run "З: образы качаются долго"                     "$PLAIN_ANS"
             check "З: пишет, что качает"                       grep -q 'качаем, прошло 15 сек' /tmp/r.log
unset PULL_SLEEP; export PULL_FAIL=quiet
rm -rf /opt/n8n; run "З2: тихое скачивание упало, повтор удался"  "$PLAIN_ANS"
unset PULL_FAIL; export PULL_FAIL=all
rm -rf /opt/n8n
printf "%-52s" "З3: скачать не удалось совсем"
if printf "$PLAIN_ANS" | bash "${INSTALL_SH:-/work/install.sh}" >/tmp/r.log 2>&1; then
  echo "ПРОВАЛ (установка не должна была пройти)"; FAILED=1
elif grep -q 'Не удалось скачать образы Docker' /tmp/r.log; then echo "OK"
else echo "ПРОВАЛ (нет понятной причины)"; tail -5 /tmp/r.log; FAILED=1; fi
unset PULL_FAIL; export CERT_WAIT=35; rm -f /tmp/cert-t0
rm -rf /opt/n8n; run "З4: сертификат выдаётся не сразу"           "$PLAIN_ANS"
             check "З4: пишет, сколько ждём"                    grep -q 'ждём сертификат, прошло 30 сек из 10 мин' /tmp/r.log
             check "З4: дождался"                               grep -q 'HTTPS работает' /tmp/r.log
unset CERT_WAIT

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "ЕСТЬ ПРОВАЛИВШИЕСЯ СЦЕНАРИИ"
  exit 1
fi
echo
echo "все сценарии прошли"
