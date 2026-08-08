#!/usr/bin/env bash
# Проверяет, что установщик понимает адрес прокси в любом привычном виде.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# берём функции разбора прямо из установщика - тестируем то, что поедет на сервер
eval "$(awk '/^is_hostport\(\) \{/{on=1} /^# Отправка сообщения в Telegram/{on=0} on' "$ROOT/install.sh")"

ok=0; bad=0
t() {
  got="$(normalize_proxy "$1" 2>/dev/null || echo ОТКАЗ)"
  if [ "$got" = "$2" ]; then ok=$((ok+1))
  else printf '  ПЛОХО %-42s -> %s (ждали %s)\n' "$1" "$got" "$2"; bad=$((bad+1)); fi
}

t "203.0.113.10:10000@user:pass"         "http://user:pass@203.0.113.10:10000"
t "user:pass@203.0.113.10:10000"         "http://user:pass@203.0.113.10:10000"
t "203.0.113.10:10000:user:pass"         "http://user:pass@203.0.113.10:10000"
t "user:pass:203.0.113.10:10000"         "http://user:pass@203.0.113.10:10000"
t "http://user:pass@203.0.113.10:10000"  "http://user:pass@203.0.113.10:10000"
t "https://user:pass@203.0.113.10:10000" "http://user:pass@203.0.113.10:10000"
t "203.0.113.10:10000"                   "http://203.0.113.10:10000"
t "proxy.example.de:3128@user:pass"        "http://user:pass@proxy.example.de:3128"
t "socks5://user:pass@1.2.3.4:1080"        "socks5://user:pass@1.2.3.4:1080"
t "socks5h://1.2.3.4:1080"                 "socks5://1.2.3.4:1080"
t 'user:pa$w0rd@1.2.3.4:8080'              'http://user:pa$w0rd@1.2.3.4:8080'
t "user:p@ssword@1.2.3.4:8080"             "http://user:p@ssword@1.2.3.4:8080"
t " 203.0.113.10:10000@user:pass "       "http://user:pass@203.0.113.10:10000"
t "просто-текст"                           "ОТКАЗ"
t "1.2.3.4"                                "ОТКАЗ"
t "socks4://1.2.3.4:1080"                  "ОТКАЗ"

[ "$(mask_proxy 'http://u:SECRET@1.2.3.4:80')" = "http://u:*****@1.2.3.4:80" ] \
  || { echo "  ПЛОХО: пароль не маскируется"; bad=$((bad+1)); }

if [ "$bad" -ne 0 ]; then echo "  разбор прокси: $bad ошибок"; exit 1; fi
echo "  разбор адреса прокси: $ok форматов, все верно"
