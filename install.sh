#!/usr/bin/env bash
# =============================================================================
#  Установщик n8n "под ключ": Docker + PostgreSQL + Caddy (HTTPS автоматически)
#  Для Ubuntu / Debian. Запускать от root на чистом VPS.
#
#  Запуск одной командой:
#    curl -sSL https://raw.githubusercontent.com/generalovai/n8n-install/main/install.sh -o n8n-install.sh && bash n8n-install.sh
#
#  Умеет:
#    - домен от любого регистратора (reg.ru и т.п.) - сертификат по HTTP;
#    - домен на DNS Cloudflare - сам создаёт A-запись и берёт сертификат по DNS
#      (работает, даже если провайдер закрыл 80 порт);
#    - прокси для серверов в РФ: и для скачивания образов, и для запросов из нод.
#
#  Скрипт безопасно перезапускать: он не портит то, что уже сделано.
# =============================================================================

set -Eeuo pipefail

# ВАЖНО: имя не VERSION - его затирает /etc/os-release, который мы читаем ниже
INST_VER="2.1.0"
DIR="/opt/n8n"
ENV_FILE="$DIR/.env"
LOG="$([ "$(id -u)" -eq 0 ] && echo /var/log/n8n-install.log || echo /tmp/n8n-install.log)"

# ---------- оформление -------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[0m'; GREEN=$'\033[32m'; RED=$'\033[31m'
  YEL=$'\033[33m'; CYAN=$'\033[36m'
else
  B=""; R=""; GREEN=""; RED=""; YEL=""; CYAN=""
fi

say()   { printf '%s\n' "$*"; }
ok()    { printf '%s  [готово]%s %s\n' "$GREEN" "$R" "$*"; }
info()  { printf '%s  ->%s %s\n' "$CYAN" "$R" "$*"; }
warn()  { printf '%s  ! %s%s\n' "$YEL" "$*" "$R"; }
step()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }

die() {
  printf '\n%s================ ОШИБКА ================%s\n' "$RED" "$R"
  printf '%s\n' "$*"
  printf '\nЧто делать:\n'
  printf '  1. Прочитайте сообщение выше - там написана причина.\n'
  printf '  2. Исправьте её и запустите ту же команду ещё раз.\n'
  printf '     Скрипт продолжит с того места, где остановился, ничего не сломав.\n'
  printf '  3. Подробный лог: %s\n' "$LOG"
  exit 1
}

trap 'die "Команда на строке $LINENO завершилась с ошибкой. Полный лог: '"$LOG"'"' ERR

exec > >(tee -a "$LOG") 2>&1
printf '\n===== запуск установщика %s =====\n' "$(date '+%F %T')" >> "$LOG"

# ---------- ввод от пользователя --------------------------------------------
# Вопросы задаём в терминал, даже если сам скрипт пришёл из curl.
if exec 3</dev/tty 2>/dev/null; then :; else exec 3<&0; fi

no_input() {
  die "Скрипт не может задать вам вопрос: терминал недоступен.
Скорее всего, вы запустили его так:  curl ... | bash
Скачайте файл и запустите отдельной командой:
  curl -sSL <ссылка на скрипт> -o n8n-install.sh
  bash n8n-install.sh"
}

ask() { # ask ПЕРЕМЕННАЯ "Вопрос" "значение_по_умолчанию"
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  while :; do
    if [ -n "$__def" ]; then
      printf '%s%s%s [%s]: ' "$B" "$__q" "$R" "$__def"
    else
      printf '%s%s%s: ' "$B" "$__q" "$R"
    fi
    IFS= read -r -u 3 __ans || no_input
    __ans="${__ans:-$__def}"
    __ans="$(printf '%s' "$__ans" | tr -d '[:space:]')"
    [ -n "$__ans" ] && break
    warn "Нужно что-то ввести."
  done
  printf -v "$__var" '%s' "$__ans"
}

ask_secret() { # ask_secret ПЕРЕМЕННАЯ "Вопрос" - ввод не показывается на экране
  local __var="$1" __q="$2" __ans=""
  printf '%s%s%s: ' "$B" "$__q" "$R"
  IFS= read -r -s -u 3 __ans || no_input
  printf '\n'
  printf -v "$__var" '%s' "$(printf '%s' "$__ans" | tr -d '[:space:]')"
}

ask_yes() { # ask_yes "Вопрос" "д|н" -> код 0 = да
  # Раньше всё, что не совпало точно с "д", молча считалось отказом.
  # На вопросе вроде "нужен ли прокси" такая ошибка ломает всю установку,
  # поэтому непонятный ответ теперь переспрашиваем, а не додумываем.
  local __q="$1" __def="${2:-д}" __a=""
  while :; do
    printf '%s%s%s (y/n) [%s]: ' "$B" "$__q" "$R" "$__def"
    IFS= read -r -u 3 __a || no_input
    __a="$(printf '%s' "$__a" | tr -d '[:space:]')"   # пробелы и перевод строки
    [ -n "$__a" ] || __a="$__def"
    case "$__a" in
      д|Д|да|Да|дА|ДА|y|Y|yes|Yes|YES|1)   return 0 ;;
      н|Н|нет|Нет|неТ|НЕТ|n|N|no|No|NO|0)  return 1 ;;
      *) warn "Не понял ответ «$__a». Напишите  y  (да) или  n  (нет)." ;;
    esac
  done
}

# ---------- вспомогательное --------------------------------------------------
gen_secret() { openssl rand -hex 24; }

# Docker Compose подставляет переменные и в значениях .env: одиночный $ в
# пароле прокси он съедает молча (проверено). Поэтому в .env пишем $$,
# а при чтении обратно разворачиваем.
env_esc()   { printf '%s' "$1" | sed 's/\$/$$/g'; }
env_unesc() { printf '%s' "$1" | sed 's/\$\$/$/g'; }

env_get() { # читает значение из уже существующего .env
  [ -f "$ENV_FILE" ] || return 1
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-)" || return 1
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

dc() { docker compose --project-directory "$DIR" "$@"; }

ask_proxy() {   # спрашивает адрес прокси и проверяет, что через него есть интернет
  while :; do
    ask PROXY_RAW "Адрес прокси"
    if PROXY_URL="$(normalize_proxy "$PROXY_RAW")"; then
      say "  Понял так: $B$(mask_proxy "$PROXY_URL")$R"
      ask_yes "  Всё верно?" "y" || { warn "Хорошо, введите заново."; continue; }
    else
      warn "Не разобрал этот адрес."
      say  "  Подойдёт любой из привычных видов, например:"
      say  "    http://логин:пароль@203.0.113.10:10000"
      say  "    203.0.113.10:10000@логин:пароль"
      say  "    203.0.113.10:10000:логин:пароль"
      say  "  Если прокси без пароля - просто  203.0.113.10:10000"
      continue
    fi
    case "$PROXY_URL" in
      socks5*)
        _cred="${PROXY_URL#*://}"
        case "$_cred" in
          *@*)
            _pass="${_cred%@*}"; _pass="${_pass#*:}"
            case "$_pass" in
              *@*|*\"*)
                warn "В пароле прокси есть символ @ или кавычка."
                say  "  К сожалению, мост socks5 такие пароли не понимает."
                say  "  Варианты: смените пароль у прокси или возьмите http-прокси."
                if ask_yes "Ввести другой адрес?" "y"; then continue; else PROXY_URL=""; break; fi ;;
            esac ;;
        esac ;;
    esac
    info "Проверяем прокси (до 40 секунд)..."
    _pc="$(proxy_for_curl "$PROXY_URL")"
    if curl --proxy "$_pc" -sS --max-time 20 -o /dev/null https://api.ipify.org 2>/dev/null \
       || curl --proxy "$_pc" -sS --max-time 20 -o /dev/null https://www.google.com 2>/dev/null; then
      ok "Прокси работает"
      break
    fi
    warn "Через этот прокси не удалось выйти в интернет."
    ask_yes "Ввести другой адрес?" "y" || { PROXY_URL=""; break; }
  done
}


# Ответы человека и сгенерированные пароли сохраняем СРАЗУ, как только они
# собраны, - до установки Docker и прочих долгих шагов. Если что-то упадёт
# на середине, при повторном запуске не придётся вводить всё заново.
write_env() {
  mkdir -p "$DIR"
  # umask меняем только на время записи .env и сразу возвращаем: иначе все
  # папки, созданные дальше, получают права 700 и контейнеры в них не войдут
  local _old_umask; _old_umask="$(umask)"
  umask 077
  {
    echo "# Создано установщиком n8n v$INST_VER, $(date '+%F %T')"
    echo "# ВНИМАНИЕ: здесь пароли и ключ шифрования. Никому не показывайте."
    echo
    echo "DATA_FOLDER=$DIR"
    echo "N8N_FQDN=$FQDN"
    echo "SSL_EMAIL=$SSL_EMAIL"
    echo "GENERIC_TIMEZONE=$GENERIC_TIMEZONE"
    echo "INSTALLER_VERSION=$INST_VER"
    echo "N8N_IMAGE_TAG=latest"
    echo "AUTO_UPDATE=$AUTO_UPDATE"
    echo "TG_TOKEN=$(env_esc "$TG_TOKEN")"
    echo "TG_CHAT=$TG_CHAT"
    echo "NODE_MEM_MB=$NODE_MEM_MB"
    echo "N8N_PROXY_HOPS=$N8N_PROXY_HOPS"
    echo "PUSH_BACKEND=$PUSH_BACKEND"
    echo
    echo "TLS_MODE=$TLS_MODE"
    echo "CF_PROXIED=$CF_PROXIED"
    [ -n "$CF_API_TOKEN" ] && echo "CF_API_TOKEN=$(env_esc "$CF_API_TOKEN")"
    echo
    echo "PROXY_URL=$(env_esc "$PROXY_URL")"
    echo "PROXY_KIND=$PROXY_KIND"
    echo "CONTAINER_PROXY=$(env_esc "$CONTAINER_PROXY")"
    echo
    echo "# Ключ шифрования: им зашифрованы ВСЕ ваши доступы."
    echo "# Потеряете - восстановить их будет невозможно."
    echo "N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY"
    echo
    echo "POSTGRES_DB=n8n"
    echo "POSTGRES_USER=postgres"
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    echo "POSTGRES_NON_ROOT_USER=n8n"
    echo "POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_NON_ROOT_PASSWORD"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  umask "$_old_umask"
}


# Для socks5 просим curl резолвить имена НА СТОРОНЕ прокси (socks5h): если у
# сервера подменён или заблокирован DNS, обычный socks5 всё равно не сработает.
proxy_for_curl() { printf '%s' "${1/#socks5:\/\//socks5h://}"; }

# Провайдеры выдают адрес прокси в самых разных видах. Принимаем все частые
# и приводим к одному: схема://логин:пароль@хост:порт
#   http://логин:пароль@хост:порт   (уже правильный)
#   хост:порт@логин:пароль          (частый у российских продавцов)
#   логин:пароль@хост:порт
#   хост:порт:логин:пароль
#   логин:пароль:хост:порт
#   хост:порт                       (без авторизации)
is_hostport() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+:[0-9]{1,5}$'; }

normalize_proxy() {
  local raw="$1" scheme="" rest="" left="" right="" cred="" host=""
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  case "$raw" in
    http://*)    scheme=http;   rest="${raw#http://}" ;;
    https://*)   scheme=http;   rest="${raw#https://}" ;;
    socks5h://*) scheme=socks5; rest="${raw#socks5h://}" ;;
    socks5://*)  scheme=socks5; rest="${raw#socks5://}" ;;
    socks4://*)  return 1 ;;
    socks://*)   scheme=socks5; rest="${raw#socks://}" ;;
    *)           scheme="";     rest="$raw" ;;
  esac

  if [ "${rest#*@}" != "$rest" ]; then
    # делим по последней собаке, а если не вышло - по первой
    left="${rest%@*}"; right="${rest##*@}"
    if   is_hostport "$right"; then host="$right"; cred="$left"
    elif is_hostport "$left";  then host="$left";  cred="$right"
    else
      left="${rest%%@*}"; right="${rest#*@}"
      if   is_hostport "$left";  then host="$left";  cred="$right"
      elif is_hostport "$right"; then host="$right"; cred="$left"
      else return 1
      fi
    fi
  else
    case "$(printf '%s' "$rest" | awk -F: '{print NF}')" in
      2) is_hostport "$rest" || return 1; host="$rest"; cred="" ;;
      4) local a b c d
         a="${rest%%:*}"; rest="${rest#*:}"
         b="${rest%%:*}"; rest="${rest#*:}"
         c="${rest%%:*}"; d="${rest#*:}"
         if   is_hostport "$a:$b"; then host="$a:$b"; cred="$c:$d"
         elif is_hostport "$c:$d"; then host="$c:$d"; cred="$a:$b"
         else return 1
         fi ;;
      *) return 1 ;;
    esac
  fi

  [ -n "$scheme" ] || scheme=http
  if [ -n "$cred" ]; then printf '%s://%s@%s' "$scheme" "$cred" "$host"
  else printf '%s://%s' "$scheme" "$host"; fi
}

# Показать адрес без пароля - чтобы человек убедился, что мы поняли правильно
mask_proxy() {
  printf '%s' "$1" | sed -E 's|(://[^:@]+:)[^@]*@|\1*****@|'
}

# Отправка сообщения в Telegram. Никогда не роняет вызвавший её код:
# уведомление - вещь полезная, но не критичная.
tg_send() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  curl -sS --max-time 20 -o /dev/null \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=$1" \
    --data "disable_web_page_preview=true" 2>/dev/null || true
}

# curl, который при необходимости идёт через прокси пользователя.
# Если через прокси не вышло - пробуем напрямую: бывает, что прокси
# закрывает какие-то адреса, а сервер до них дотягивается сам.
pcurl() {
  if [ -n "${PROXY_URL:-}" ]; then
    curl --proxy "$(proxy_for_curl "$PROXY_URL")" "$@" || curl "$@"
  else
    curl "$@"
  fi
}

# =============================================================================
step "Установщик n8n v$INST_VER"
cat <<'TXT'

  Скрипт сам поставит на сервер:
    - Docker
    - базу данных PostgreSQL
    - n8n (последняя версия, режим "всё включено")
    - Caddy - он бесплатно и автоматически выдаст HTTPS-сертификат

  Что нужно приготовить заранее:
    1. Домен. Подойдёт любой, самый дешёвый. На reg.ru зоны вроде .ru
       стоят около 200 руб/год - этого достаточно.
    2. Если сервер в России и вам нужны зарубежные сервисы (OpenAI,
       Telegram и подобные) - приготовьте адрес своего прокси.

  Дальше просто отвечайте на вопросы. Займёт 5-10 минут.

TXT

# ---------- 0. проверки ------------------------------------------------------
step "Шаг 0 из 10. Проверяем сервер"

[ "$(id -u)" -eq 0 ] || die "Скрипт нужно запускать от имени root.
Добавьте в начало команды  sudo  :
  sudo bash n8n-install.sh"

[ -r /etc/os-release ] || die "Не удалось определить операционную систему. Нужна Ubuntu или Debian."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ok "Система: ${PRETTY_NAME:-$ID}" ;;
  *) die "Нужна Ubuntu или Debian. У вас: ${PRETTY_NAME:-неизвестно}.
Возьмите VPS с Ubuntu 22.04 или новее." ;;
esac

case "$(uname -m)" in
  x86_64|aarch64|arm64) ok "Процессор: $(uname -m)" ;;
  *) die "Неподдерживаемая архитектура процессора: $(uname -m). Нужен x86_64 или arm64." ;;
esac

RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc 2>/dev/null || echo 1)
info "Оперативная память: ${RAM_MB} МБ, ядер процессора: ${CPU_CORES}"

# На практике n8n со своей базой и сборкой community-нод на 2 ГБ падает по памяти.
# Рекомендуем 2 ядра и 4 ГБ - это тот минимум, на котором всё работает спокойно.
if [ "$RAM_MB" -lt 3500 ] || [ "$CPU_CORES" -lt 2 ]; then
  warn "Этот сервер слабее, чем нужно для спокойной работы."
  say  "  У вас: ${CPU_CORES} ядр(о/а), ${RAM_MB} МБ памяти."
  say  "  Рекомендуем: 2 ядра и 4 ГБ памяти."
  say  "  На меньшем n8n обычно ставится, но потом падает с ошибкой нехватки памяти -"
  say  "  особенно когда устанавливаете community-ноды или обрабатываете файлы."
  say  "  Дешевле сразу взять сервер побольше, чем потом переносить всё заново."
  ask_yes "Всё равно продолжить установку на этом сервере?" "n" \
    || die "Установка отменена. Возьмите сервер с 2 ядрами и 4 ГБ памяти и запустите команду снова.
Если сервер уже оплачен - у большинства провайдеров тариф можно повысить в панели за пару минут."
fi

DISK_GB=$(df -P -k / | awk 'NR==2 {print int($4/1024/1024)}')
info "Свободно на диске: ${DISK_GB} ГБ"
[ "${DISK_GB:-0}" -ge 5 ] || die "На диске меньше 5 ГБ свободного места - для Docker и n8n этого не хватит."

export DEBIAN_FRONTEND=noninteractive
info "Ставим базовые утилиты (это может занять минуту)..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl dnsutils ufw cron tar gzip tzdata jq >/dev/null
ok "Базовые утилиты на месте"

SERVER_IP="$(curl -4 -sS --max-time 15 https://ifconfig.me 2>/dev/null || curl -4 -sS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
[ -n "$SERVER_IP" ] || die "Не удалось узнать внешний IP-адрес сервера. Проверьте, есть ли на сервере интернет."
ok "Внешний IP этого сервера: $B$SERVER_IP$R"

PREV_VERSION="$(env_get INSTALLER_VERSION || true)"
if [ -n "$PREV_VERSION" ] && [ "$PREV_VERSION" != "$INST_VER" ]; then
  ok "Обновляем установку с версии $PREV_VERSION до $INST_VER"
fi

# ---------- 1. домен ---------------------------------------------------------
step "Шаг 1 из 10. Ваш домен"

FQDN="$(env_get N8N_FQDN || true)"
if [ -n "$FQDN" ]; then
  say "Найдена прошлая установка на адресе: $B$FQDN$R"
  ask_yes "Оставить этот же адрес?" "y" || FQDN=""
fi

if [ -z "$FQDN" ]; then
  cat <<'TXT'

  Введите адрес, по которому будет открываться n8n.
  Обычно это поддомен вашего домена, например:  n8n.мойсайт.ru

  Если домена ещё нет - купите любой (reg.ru, около 200 руб/год),
  потом вернитесь и запустите эту команду снова.

TXT
  while :; do
    ask FQDN "Адрес для n8n"
    FQDN="${FQDN,,}"; FQDN="${FQDN#http://}"; FQDN="${FQDN#https://}"; FQDN="${FQDN%%/*}"
    case "$FQDN" in
      *.*.*|*.*) ;;
      *) warn "Это не похоже на адрес. Нужен вид  n8n.мойсайт.ru"; continue ;;
    esac
    # кириллица в домене: сертификат на такой адрес выдаётся не всегда
    if printf '%s' "$FQDN" | LC_ALL=C grep -q '[^a-z0-9.-]'; then
      warn "В адресе есть буквы не латиницей (например домен в зоне .рф)."
      say  "  С такими адресами HTTPS-сертификат выдаётся не всегда."
      say  "  Надёжнее взять обычный домен латиницей - например мойсайт.ru."
      ask_yes "Всё равно продолжить с этим адресом?" "n" || continue
    fi
    break
  done
fi
ok "Адрес n8n: $B$FQDN$R"

# ---------- 2. прокси для зарубежных сервисов --------------------------------
step "Шаг 2 из 10. Прокси для зарубежных сервисов"

PROXY_URL="$(env_unesc "$(env_get PROXY_URL || true)")"
if [ -n "$PROXY_URL" ]; then
  # Раньше здесь был вопрос "изменить или убрать?" - после него было непонятно,
  # что вообще произошло с прокси. Теперь спрашиваем прямо.
  say "  С прошлой установки сохранён прокси: $B$(mask_proxy "$PROXY_URL")$R"
  if ask_yes "Оставить его?" "y"; then
    ok "Оставляем прежний прокси"
    NEED_PROXY_Q=нет
  else
    PROXY_URL=""
    say "  Хорошо, прежний прокси убран."
    NEED_PROXY_Q=да
  fi
else
  NEED_PROXY_Q=да
fi

if [ "$NEED_PROXY_Q" = "да" ]; then
  cat <<'TXT'

  Это нужно, только если сервер стоит в России или в другой стране,
  откуда не открываются зарубежные сервисы. Прокси решает сразу
  две задачи: скачать образы Docker и дать нодам n8n ходить
  в OpenAI, Telegram и другие сервисы.

  Если сервер за границей (Германия, Нидерланды и т.п.) - прокси не нужен.

  Формат адреса:
    http://логин:пароль@адрес:порт
    socks5://логин:пароль@адрес:порт   (подойдёт и без логина с паролем)

TXT
  if ask_yes "Использовать прокси?" "n"; then
    ask_proxy
  fi
fi

# Человек мог отказаться от прокси по ошибке - а с российского сервера без него
# установка дальше просто не пройдёт. Проверяем сразу, а не через три шага,
# когда уже непонятно, что пошло не так.
if [ -z "$PROXY_URL" ]; then
  info "Проверяю, открыты ли нужные сайты напрямую..."
  if curl -sS -o /dev/null --max-time 20 https://get.docker.com 2>/dev/null; then
    ok "Открыты - прокси действительно не нужен"
  else
    warn "С этого сервера не открывается get.docker.com."
    say  "  Для серверов в России это обычное дело. Без прокси установка"
    say  "  дальше не пройдёт: Docker будет неоткуда скачать."
    if ask_yes "Указать прокси?" "y"; then
      ask_proxy
    else
      warn "Продолжаем без прокси - установка, скорее всего, прервётся на Docker."
    fi
  fi
fi

# Контейнерам нужен именно HTTP-прокси. Если у человека socks5, поднимем
# маленький мост socks5 -> http (tinyproxy) внутри Docker.
PROXY_KIND=none          # none | http | socks5
CONTAINER_PROXY=""       # что подставим контейнеру n8n
if [ -n "$PROXY_URL" ]; then
  case "$PROXY_URL" in
    socks5://*|socks5h://*) PROXY_KIND=socks5; CONTAINER_PROXY="http://proxy-bridge:8888" ;;
    *)                      PROXY_KIND=http;   CONTAINER_PROXY="$PROXY_URL" ;;
  esac
  ok "Прокси будет использоваться: $( [ "$PROXY_KIND" = socks5 ] && echo 'socks5 (поднимем мост для контейнеров)' || echo 'http' )"
else
  ok "Работаем без прокси"
fi

# ---------- 3. как получать HTTPS-сертификат ---------------------------------
step "Шаг 3 из 10. Домен и HTTPS"

TLS_MODE="$(env_get TLS_MODE || true)"
CF_API_TOKEN="$(env_unesc "$(env_get CF_API_TOKEN || true)")"
CF_PROXIED="$(env_get CF_PROXIED || echo false)"

if [ -n "$TLS_MODE" ] && ask_yes "Оставить прежние настройки HTTPS (режим: $TLS_MODE)?" "y"; then
  :
else
  TLS_MODE=""; CF_API_TOKEN=""; CF_PROXIED=false
  cat <<'TXT'

  Есть два пути.

  1. DNS вашего домена управляется через Cloudflare (бесплатно, даже
     если сам домен куплен на reg.ru - там просто меняются NS-серверы).
     Тогда скрипт сам создаст нужную запись и получит сертификат.
     Это надёжнее: работает, даже если провайдер закрыл 80 порт.

  2. Обычный вариант: DNS у регистратора (reg.ru и любые другие).
     Вы один раз создадите A-запись руками, дальше всё сделает скрипт.

TXT
  if ask_yes "Ваш домен подключён к Cloudflare?" "n"; then
    TLS_MODE=cloudflare
  else
    TLS_MODE=http
  fi
fi

if [ "$TLS_MODE" = "cloudflare" ]; then
  if [ -z "$CF_API_TOKEN" ]; then
    cat <<'TXT'

  Нужен API-токен Cloudflare. Как его создать:
    1. Зайдите на https://dash.cloudflare.com/profile/api-tokens
    2. Create Token -> Edit zone DNS (Use template)
    3. В Zone Resources выберите свой домен
    4. Continue -> Create Token -> скопируйте токен

  Токен даёт права только на записи DNS этого домена.
  При вводе он не будет виден на экране - это нормально, просто вставьте и нажмите Enter.

TXT
    while :; do
      ask_secret CF_API_TOKEN "Вставьте токен Cloudflare"
      [ -n "$CF_API_TOKEN" ] || { warn "Пусто. Попробуйте вставить ещё раз."; continue; }
      info "Проверяем токен..."
      if pcurl -sS --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" \
           https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null | jq -e '.success == true' >/dev/null; then
        ok "Токен принят Cloudflare"
        break
      fi
      warn "Cloudflare не принял этот токен. Проверьте, что скопировали его целиком."
      ask_yes "Попробовать ещё раз?" "y" || die "Без рабочего токена вариант с Cloudflare не заработает.
Запустите скрипт заново и выберите обычный вариант с A-записью."
    done
  fi

  # Ищем зону: спрашиваем Cloudflare про каждый вариант домена по очереди
  # (n8n.мойсайт.ru -> мойсайт.ru -> ...). Так надёжнее, чем тянуть список всех
  # зон: у списка есть ограничение на размер страницы.
  info "Ищем ваш домен в аккаунте Cloudflare..."
  CF_ZONE_ID=""; CF_ZONE_NAME=""; CF_TRIED=""
  CAND="$FQDN"
  while [ "${CAND#*.}" != "$CAND" ]; do
    CF_TRIED="$CF_TRIED
  - $CAND"
    CF_Z="$(pcurl -sS --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$CAND" 2>/dev/null || echo '{}')"
    CF_ZONE_ID="$(printf '%s' "$CF_Z" | jq -r '.result[0].id // empty')"
    if [ -n "$CF_ZONE_ID" ]; then CF_ZONE_NAME="$CAND"; break; fi
    CAND="${CAND#*.}"
  done

  [ -n "$CF_ZONE_ID" ] || die "В аккаунте Cloudflare не нашёлся домен для адреса $FQDN.
Проверяли такие варианты:$CF_TRIED

Что проверить:
  - домен действительно добавлен в Cloudflare (в списке Websites);
  - токен выдан на ЭТОТ домен (в шаблоне Edit zone DNS есть выбор Zone Resources);
  - у токена есть право Zone:Read - без него он домен не видит."
  ok "Домен найден в Cloudflare: $CF_ZONE_NAME"

  if [ "$CF_PROXIED" != "true" ]; then
    cat <<'TXT'

  Оранжевое облако Cloudflare прячет IP сервера и защищает от атак,
  но у бесплатного тарифа есть ограничение: файлы больше 100 МБ
  через него не пройдут. Для n8n это обычно неудобно.

TXT
    if ask_yes "Включить оранжевое облако (скрыть IP сервера)?" "n"; then
      CF_PROXIED=true
    else
      CF_PROXIED=false
    fi
  fi

  # создаём или обновляем A-запись
  info "Настраиваем A-запись $FQDN -> $SERVER_IP ..."
  CF_REC_ID="$(pcurl -sS --max-time 30 -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$FQDN" 2>/dev/null \
      | jq -r '.result[0].id // empty')"
  # у проксируемых записей Cloudflare ожидает ttl=1 ("автоматически")
  CF_TTL=120; [ "$CF_PROXIED" = "true" ] && CF_TTL=1
  CF_BODY="$(jq -nc --arg n "$FQDN" --arg c "$SERVER_IP" --argjson p "$CF_PROXIED" --argjson t "$CF_TTL" \
      '{type:"A",name:$n,content:$c,ttl:$t,proxied:$p}')"
  if [ -n "$CF_REC_ID" ]; then
    CF_RES="$(pcurl -sS --max-time 30 -X PUT -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" --data "$CF_BODY" \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_REC_ID" 2>/dev/null || echo '{}')"
  else
    CF_RES="$(pcurl -sS --max-time 30 -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" --data "$CF_BODY" \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" 2>/dev/null || echo '{}')"
  fi
  printf '%s' "$CF_RES" | jq -e '.success == true' >/dev/null || die "Cloudflare не дал изменить A-запись.
Ответ Cloudflare: $(printf '%s' "$CF_RES" | jq -r '.errors[]?.message' | head -3)
Чаще всего у токена не хватает прав: нужен шаблон Edit zone DNS именно на этот домен."
  ok "A-запись настроена (оранжевое облако: $([ "$CF_PROXIED" = true ] && echo включено || echo выключено))"

else
  # обычный вариант: A-запись руками.
  # Если адрес без поддомена (мойсайт.ru) - в панели это записывается как @
  REC_NAME="${FQDN%%.*}"
  [ "$(printf '%s' "$FQDN" | tr -cd . | wc -c)" -le 1 ] && REC_NAME="@"
  cat <<TXT

  Зайдите в панель управления доменом (например, на reg.ru это
  раздел "Управление зоной DNS") и создайте запись:

      Тип:      A
      Имя:      $REC_NAME
      Значение: $SERVER_IP

  Записи обычно расходятся за 5-30 минут.

TXT
  while :; do
    info "Проверяем, куда сейчас указывает $FQDN ..."
    DNS_IP="$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null | tail -n1 || true)"
    if [ "$DNS_IP" = "$SERVER_IP" ]; then
      ok "Домен указывает на этот сервер"
      break
    fi
    warn "Пока указывает на: ${DNS_IP:-(запись не найдена)}, а нужен $SERVER_IP"

    # Частая путаница: человек правит запись у регистратора, а домен давно
    # переведён на чужие DNS - и правки никто не видит. Показываем, где он живёт.
    NS_ZONE="$FQDN"; NS_LIST=""
    while [ "${NS_ZONE#*.}" != "$NS_ZONE" ]; do
      NS_LIST="$(dig +short NS "$NS_ZONE" @1.1.1.1 2>/dev/null | sed 's/\.$//' | tr '\n' ' ')"
      [ -n "$NS_LIST" ] && break
      NS_ZONE="${NS_ZONE#*.}"
    done
    if [ -n "$NS_LIST" ]; then
      say "  DNS домена $NS_ZONE обслуживают: $B$NS_LIST$R"
      case "$NS_LIST" in
        *cloudflare*)
          say "  ${YEL}Это серверы Cloudflare - значит запись надо создавать в Cloudflare,${R}"
          say "  ${YEL}а не в панели регистратора: там правки ни на что не влияют.${R}"
          say "  Проще всего: прервите установку (Ctrl+C), запустите её снова"
          say "  и на вопросе про Cloudflare ответьте да - скрипт создаст запись сам." ;;
        *)
          say "  Если это не те серверы, где вы правите запись - правки не сработают." ;;
      esac
    fi
    if ask_yes "Запись уже создана - проверить ещё раз?" "y"; then continue; fi
    ask_yes "Продолжить без проверки? (сертификат выдастся позже сам, когда DNS обновится)" "n" && break
  done
fi

# при оранжевом облаке между гостем и n8n два прокси, а не один
N8N_PROXY_HOPS=1
PUSH_BACKEND=websocket
[ "$CF_PROXIED" = "true" ] && N8N_PROXY_HOPS=2

# ---------- 4. почта и часовой пояс -----------------------------------------
step "Шаг 4 из 10. Почта и часовой пояс"

SSL_EMAIL_DEF="$(env_get SSL_EMAIL || true)"
say "Почта нужна только для бесплатного сертификата (напомнят, если он истекает)."
ask SSL_EMAIL "Ваш e-mail" "${SSL_EMAIL_DEF:-admin@${FQDN#*.}}"

TZ_DEF="$(env_get GENERIC_TIMEZONE || true)"
say ""
cat <<'TXT'
  Часовой пояс нужен, чтобы задачи по расписанию срабатывали вовремя
  и ночные копии делались ночью, а не днём.

  Напишите просто вашу разницу с UTC:
     Калининград +2     Москва, Питер +3     Самара +4
     Екатеринбург +5    Омск +6              Новосибирск, Красноярск +7
     Иркутск +8         Якутск +9            Владивосток +10
     Минск +3           Алматы +5            Тбилиси +4     Ереван +4

  Если у вас переводят часы (Украина, Европа) - напишите название пояса,
  например  Europe/Kyiv  или  Europe/Berlin

TXT
# Принимаем и цифру со смещением, и полное имя пояса - кому как привычнее.
# Смещение переводим в настоящий пояс: так и n8n понимает, и человеку
# в его настройках видно знакомое название.
offset_to_zone() {
  case "$1" in
    2)  echo Europe/Kaliningrad ;;   3)  echo Europe/Moscow ;;
    4)  echo Europe/Samara ;;        5)  echo Asia/Yekaterinburg ;;
    6)  echo Asia/Omsk ;;            7)  echo Asia/Novosibirsk ;;
    8)  echo Asia/Irkutsk ;;         9)  echo Asia/Yakutsk ;;
    10) echo Asia/Vladivostok ;;     11) echo Asia/Magadan ;;
    12) echo Asia/Kamchatka ;;       0)  echo UTC ;;
    # для остальных смещений берём технический пояс с ровно этой разницей
    # (в имени Etc знак перевёрнут - это особенность стандарта)
    -*) echo "Etc/GMT+${1#-}" ;;
    *)  echo "Etc/GMT-$1" ;;
  esac
}

while :; do
  ask TZ_IN "Ваш часовой пояс" "${TZ_DEF:-+3}"
  case "$TZ_IN" in
    */*)                                   # написали полное имя пояса
      GENERIC_TIMEZONE="$TZ_IN" ;;
    [+-]*[0-9]|[+-]*[0-9][0-9]|[0-9]|[0-9][0-9])   # написали смещение
      _off="${TZ_IN#+}"; _off="${_off#0}"; [ -z "$_off" ] && _off=0
      GENERIC_TIMEZONE="$(offset_to_zone "$_off")" ;;
    *)  warn "Не понял. Напишите разницу с UTC, например  +3"; continue ;;
  esac
  if [ -f "/usr/share/zoneinfo/$GENERIC_TIMEZONE" ]; then break; fi
  warn "Такого часового пояса нет. Напишите разницу с UTC, например  +3"
done
ok "Часовой пояс: $GENERIC_TIMEZONE (сейчас там $(TZ="$GENERIC_TIMEZONE" date '+%H:%M'))"

# Задания по расписанию (копии, обновления) идут по системному времени сервера,
# а на VPS это почти всегда UTC. Ставим выбранный пояс, чтобы "ночью в 2:00"
# означало ночь у владельца, а не где-то в Гринвиче.
if [ "$(cat /etc/timezone 2>/dev/null)" != "$GENERIC_TIMEZONE" ]; then
  if timedatectl set-timezone "$GENERIC_TIMEZONE" >/dev/null 2>&1; then
    :
  else
    ln -sf "/usr/share/zoneinfo/$GENERIC_TIMEZONE" /etc/localtime 2>/dev/null || true
    printf '%s\n' "$GENERIC_TIMEZONE" > /etc/timezone 2>/dev/null || true
  fi
  # cron читает часовой пояс при старте - без перезапуска он остался бы на старом
  systemctl restart cron >/dev/null 2>&1 || service cron restart >/dev/null 2>&1 || true
  ok "Время сервера переведено на $GENERIC_TIMEZONE (сейчас $(date '+%H:%M'))"
fi

AUTO_UPDATE="$(env_get AUTO_UPDATE || true)"
if [ -z "$AUTO_UPDATE" ]; then
  say ""
  cat <<'TXT'
  Обновления n8n выходят часто, и в них чинят ошибки и дыры в безопасности.
  Скрипт может обновлять n8n сам, каждую ночь в 3 часа (сразу после копии,
  по времени вашего часового пояса):

    - сначала проверит, вышла ли новая версия (если нет - ничего не делает);
    - сделает резервную копию;
    - обновит и убедится, что n8n поднялся;
    - если что-то пошло не так - сам вернёт прежнюю версию и данные.

TXT
  if ask_yes "Включить автоматическое обновление по ночам?" "y"; then
    AUTO_UPDATE=да
  else
    AUTO_UPDATE=нет
  fi
fi
ok "Автообновление: $AUTO_UPDATE"

# ---------- 5. уведомления в Telegram ----------------------------------------
step "Шаг 5 из 10. Уведомления в Telegram (по желанию)"

TG_TOKEN="$(env_unesc "$(env_get TG_TOKEN || true)")"
TG_CHAT="$(env_get TG_CHAT || true)"
TG_NAME=""
# если человек уже отказывался - не навязываемся при следующем запуске
TG_DEFAULT=y
[ -f "$ENV_FILE" ] && [ -z "$TG_CHAT" ] && TG_DEFAULT=n

if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  ok "Уведомления уже настроены с прошлого раза"
  ask_yes "Настроить заново?" "n" && { TG_TOKEN=""; TG_CHAT=""; }
fi

if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
  cat <<'TXT'

  Сервер может присылать вам сообщения в Telegram - только по делу:

    - установка завершена;
    - вышло обновление и успешно поставилось;
    - обновление не удалось, версию пришлось вернуть;
    - не получилось сделать резервную копию;
    - заканчивается место на диске;
    - n8n перестал отвечать (и когда снова заработал).

  Ежедневных сообщений "всё хорошо" не будет.

TXT
  if ask_yes "Настроить уведомления?" "$TG_DEFAULT"; then
    cat <<'TXT'

  Как получить токен бота:
    1. Откройте в Telegram @BotFather
    2. Отправьте ему  /newbot
    3. Придумайте имя бота, затем адрес (должен заканчиваться на bot)
    4. Он пришлёт строку вида 1234567890:AaBbCc... - это и есть токен

TXT
    while :; do
      ask_secret TG_TOKEN "Вставьте токен бота"
      [ -n "$TG_TOKEN" ] || { warn "Пусто, попробуйте ещё раз."; continue; }
      info "Проверяем токен..."
      TG_ME="$(pcurl -sS --max-time 30 "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo '{}')"
      if printf '%s' "$TG_ME" | jq -e '.ok == true' >/dev/null 2>&1; then
        TG_NAME="$(printf '%s' "$TG_ME" | jq -r '.result.username')"
        ok "Бот найден: @$TG_NAME"
        break
      fi
      warn "Telegram не принял этот токен - проверьте, что скопировали его целиком."
      ask_yes "Попробовать ещё раз?" "y" || { TG_TOKEN=""; break; }
    done
  fi

  # Свой ID искать не нужно: попросим написать боту и определим сами
  if [ -n "$TG_TOKEN" ]; then
    say ""
    say "  Откройте своего бота и нажмите Start (или отправьте ему любое сообщение):"
    say "     ${B}https://t.me/${TG_NAME}${R}"
    say ""
    info "Жду от вас сообщение (до 2 минут)..."
    for _ in $(seq 1 40); do
      TG_UPD="$(pcurl -sS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" 2>/dev/null || echo '{}')"
      TG_CHAT="$(printf '%s' "$TG_UPD" | jq -r '[.result[]?.message.chat.id] | last // empty' 2>/dev/null || true)"
      [ -n "$TG_CHAT" ] && break
      sleep 3
    done
    if [ -n "$TG_CHAT" ]; then
      ok "Нашёл вас, ваш ID: $TG_CHAT"
      tg_send "Проверка связи. Сюда сервер будет писать о вашем n8n."
      ok "Отправил тестовое сообщение - посмотрите, пришло ли"
    else
      warn "Сообщение так и не пришло, уведомления пока выключены."
      say  "  Это не мешает установке. Включить можно позже - просто запустите скрипт снова."
      TG_TOKEN=""; TG_CHAT=""
    fi
  fi
fi
if [ -n "$TG_CHAT" ]; then ok "Уведомления включены"; else ok "Работаем без уведомлений"; fi

# ---------- 6. секреты -------------------------------------------------------
step "Шаг 6 из 10. Пароли и ключ шифрования"

N8N_ENCRYPTION_KEY="$(env_get N8N_ENCRYPTION_KEY || true)"
if [ -n "$N8N_ENCRYPTION_KEY" ]; then
  KEY_IS_NEW=нет
  ok "Ключ шифрования от прошлой установки найден - оставляем его (иначе пропадут доступы)"
else
  N8N_ENCRYPTION_KEY="$(openssl rand -base64 32)"
  KEY_IS_NEW=да
  ok "Сгенерирован новый ключ шифрования"
fi

NODE_MEM_MB=$(( RAM_MB * 60 / 100 )); [ "$NODE_MEM_MB" -lt 512 ] && NODE_MEM_MB=512

POSTGRES_PASSWORD="$(env_get POSTGRES_PASSWORD || gen_secret)"
POSTGRES_NON_ROOT_PASSWORD="$(env_get POSTGRES_NON_ROOT_PASSWORD || gen_secret)"
ok "Пароли базы данных готовы"

write_env
ok "Ответы сохранены - если что-то прервётся, вводить заново не придётся"

# ---------- 7. Docker (и прокси для него) ------------------------------------
step "Шаг 7 из 10. Docker"

# Прокси демону Docker нужен ДО первого скачивания образов: без него из России
# образы часто не скачиваются вообще.
# Через прокси направляем ТОЛЬКО репозиторий Docker. Зеркала Ubuntu из России
# доступны напрямую, и гонять их через зарубежный прокси - это медленно
# и лишний повод для сбоя (проверено: установка падала именно на этом).
setup_apt_proxy() {
  if [ -n "$PROXY_URL" ]; then
    local ap="$PROXY_URL"
    [ "$PROXY_KIND" = "socks5" ] && ap="${PROXY_URL/#socks5:\/\//socks5h://}"
    {
      printf 'Acquire::http::Proxy::download.docker.com "%s";\n'  "$ap"
      printf 'Acquire::https::Proxy::download.docker.com "%s";\n' "$ap"
    } > /etc/apt/apt.conf.d/01n8n-proxy
  else
    rm -f /etc/apt/apt.conf.d/01n8n-proxy
  fi
}

DOCKER_PROXY_CONF=/etc/systemd/system/docker.service.d/http-proxy.conf
setup_docker_proxy() {
  mkdir -p /etc/systemd/system/docker.service.d
  local new; new="$(mktemp)"
  if [ -n "$PROXY_URL" ]; then
    {
      echo "[Service]"
      if [ "$PROXY_KIND" = "socks5" ]; then
        echo "Environment=\"ALL_PROXY=$PROXY_URL\""
      else
        echo "Environment=\"HTTP_PROXY=$PROXY_URL\""
        echo "Environment=\"HTTPS_PROXY=$PROXY_URL\""
      fi
      echo "Environment=\"NO_PROXY=localhost,127.0.0.1,::1\""
    } > "$new"
  else
    : > "$new"
  fi
  if ! cmp -s "$new" "$DOCKER_PROXY_CONF" 2>/dev/null; then
    cp "$new" "$DOCKER_PROXY_CONF"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart docker >/dev/null 2>&1 || true
    if [ -n "$PROXY_URL" ]; then ok "Docker настроен ходить через ваш прокси"; else ok "Прокси у Docker отключён"; fi
  fi
  rm -f "$new"
}

setup_apt_proxy
[ -n "$PROXY_URL" ] && ok "Репозиторий Docker направлен через ваш прокси (остальное - напрямую)"

if docker compose version >/dev/null 2>&1; then
  ok "Docker уже установлен ($(docker --version | cut -d, -f1))"
  setup_docker_proxy
else
  info "Ставим Docker с официального сайта, подождите..."
  # Скачиваем установщик Docker. Если не вышло - показываем, что именно
  # ответила сеть, и сразу проверяем обходной путь: с прокси и без него.
  DL_ERR="$(mktemp)"
  if ! pcurl -fsSL --max-time 120 https://get.docker.com -o /tmp/get-docker.sh 2>"$DL_ERR"; then
    say ""
    say "Что ответила сеть:"
    sed 's/^/    /' "$DL_ERR" | tail -5
    say ""
    say "Проверяю, откуда есть доступ к get.docker.com:"
    D_DIRECT="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://get.docker.com 2>&1 || echo "нет ответа")"
    say "    напрямую с сервера: $D_DIRECT"
    if [ -n "$PROXY_URL" ]; then
      D_VIA="$(curl --proxy "$(proxy_for_curl "$PROXY_URL")" -sS -o /dev/null -w '%{http_code}' --max-time 20 https://get.docker.com 2>&1 || echo "нет ответа")"
      say "    через ваш прокси:   $D_VIA"
    else
      say "    прокси не указан"
    fi
    rm -f "$DL_ERR"
    say ""
    if [ "$D_DIRECT" = "200" ]; then
      die "Сайт Docker с сервера открывается, но скачать не вышло.
Похоже на временный сбой сети - просто запустите команду ещё раз."
    elif [ -n "$PROXY_URL" ] && [ "${D_VIA:-}" = "200" ]; then
      die "Напрямую не открывается, а через ваш прокси - открывается.
Значит прокси рабочий, но не применился при скачивании. Запустите команду
ещё раз: этот случай уже учтён, скачивание пойдёт через прокси."
    elif [ -n "$PROXY_URL" ]; then
      die "Не открывается ни напрямую, ни через ваш прокси.
Проверьте прокси с домашнего компьютера:
  curl --proxy <ваш прокси> -sS -o /dev/null -w '%{http_code}' https://get.docker.com
Должно ответить 200. Если нет - прокси нерабочий или закончился трафик."
    else
      die "Сервер не может открыть get.docker.com напрямую - обычное дело для России.
Запустите установку заново и на шаге 2 укажите прокси."
    fi
  fi
  rm -f "$DL_ERR"

  # Вывод установщика Docker сохраняем: без него причину сбоя не узнать.
  DOCKER_OUT="$(mktemp)"
  # https_proxy - для download.docker.com; зеркала Ubuntu исключаем явно,
  # чтобы пакеты системы качались напрямую и быстро
  if ! env ${PROXY_URL:+https_proxy="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" \
        no_proxy="localhost,127.0.0.1,.ubuntu.com,.debian.org" \
        NO_PROXY="localhost,127.0.0.1,.ubuntu.com,.debian.org"} \
        sh /tmp/get-docker.sh >"$DOCKER_OUT" 2>&1; then
    cat "$DOCKER_OUT" >> "$LOG"
    say ""
    say "Что ответил установщик Docker (последние строки):"
    tail -20 "$DOCKER_OUT" | sed 's/^/    /'
    die "Не удалось установить Docker.

Смотрите строки выше - там настоящая причина. Чаще всего это одно из двух:
  - сервер в России и не может достучаться до download.docker.com;
    вернитесь на шаг 2 и укажите рабочий прокси;
  - в системе остались старые пакеты Docker и они конфликтуют;
    помогает:  apt-get remove -y docker docker-engine docker.io containerd runc

Полный вывод сохранён в $LOG"
  fi
  rm -f "$DOCKER_OUT"
  rm -f /tmp/get-docker.sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker установился, но плагин compose не работает.
Выполните:  apt-get install -y docker-compose-plugin  и запустите скрипт заново."
  ok "Docker установлен"
  setup_docker_proxy
fi

# ---------- 8. настройка сервера ---------------------------------------------
step "Шаг 8 из 10. Настраиваем сервер"

if [ "$RAM_MB" -lt 4000 ] && [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
  if [ ! -f /swapfile ]; then
    info "Создаём файл подкачки на 2 ГБ (чтобы n8n не падал от нехватки памяти)..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Файл подкачки включён"
else
  ok "Файл подкачки не требуется"
fi

if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
  ok "Автообновления безопасности уже включены"
else
  info "Включаем автоматические обновления безопасности системы..."
  apt-get install -y -qq unattended-upgrades >/dev/null
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  ok "Автообновления включены"
fi

# Порт SSH определяем сам: если он нестандартный, а мы откроем только 22,
# человек потеряет доступ к серверу.
ssh_ports_raw() {
  grep -REhi '^[[:space:]]*Port[[:space:]]+[0-9]+' \
       /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | grep -oE '[0-9]+' || true
  [ -n "${SSH_CONNECTION:-}" ] && printf '%s\n' "${SSH_CONNECTION##* }" || true
  echo 22
}
SSH_PORTS="$(ssh_ports_raw | grep -E '^[0-9]+$' | sort -un | head -5 || true)"
[ -n "$SSH_PORTS" ] || SSH_PORTS=22
info "Фаервол: наружу открыты только SSH (порт: $(echo "$SSH_PORTS" | tr '\n' ' ')), HTTP и HTTPS"
for _p in $SSH_PORTS; do ufw allow "$_p/tcp" >/dev/null 2>&1 || true; done
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 80/tcp  >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
if ufw status | head -n1 | grep -qi inactive; then
  ufw --force enable >/dev/null 2>&1 || warn "Не удалось включить ufw - пропускаем, это не критично."
fi
ok "Фаервол настроен"

# ---------- 9. файлы проекта -------------------------------------------------
step "Шаг 9 из 10. Создаём файлы n8n в $DIR"

mkdir -p "$DIR/caddy_config" "$DIR/local_files" "$DIR/backups" "$DIR/caddy_build" "$DIR/proxy_bridge"
# Права задаём явно, а не полагаемся на umask: n8n внутри контейнера работает
# под пользователем node (uid 1000) и должен читать эти папки, а в local_files
# ещё и писать.
chmod 755 "$DIR" "$DIR/caddy_config" "$DIR/caddy_build" "$DIR/proxy_bridge"
chmod 700 "$DIR/backups"
chown -R 1000:1000 "$DIR/local_files" 2>/dev/null || true
chmod 755 "$DIR/local_files"

write_env
ok "Файл настроек .env создан (доступ только для root)"

# дальше файлы должны читаться из контейнеров (postgres работает не от root)
umask 022

cat > "$DIR/init-data.sh" <<'EOF'
#!/bin/bash
set -e
if [ -n "${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
		CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
		GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
		GRANT CREATE ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
	EOSQL
fi
EOF
chmod 755 "$DIR/init-data.sh"

# --- Caddyfile ---------------------------------------------------------------
# При оранжевом облаке настоящий IP гостя приходит в заголовке Cloudflare.
# Список их сетей забираем прямо у Cloudflare. Это глобальные настройки
# сервера, внутри блока сайта Caddy их не понимает (проверено).
CF_RANGES=""
if [ "$CF_PROXIED" = "true" ]; then
  CF_RANGES="$( { pcurl -sS --max-time 20 https://www.cloudflare.com/ips-v4 2>/dev/null || true;
                  pcurl -sS --max-time 20 https://www.cloudflare.com/ips-v6 2>/dev/null || true; } \
                | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | tr '\n' ' ' || true)"
  [ -n "$CF_RANGES" ] || warn "Не удалось скачать список сетей Cloudflare - IP гостей в логах будут неточными."
fi

{
  echo '{'
  echo '	email {$SSL_EMAIL}'
  if [ -n "$CF_RANGES" ]; then
    echo '	servers {'
    echo "		trusted_proxies static $CF_RANGES"
    echo '		client_ip_headers CF-Connecting-IP X-Forwarded-For'
    echo '	}'
  fi
  echo '}'
  echo
  echo '{$N8N_FQDN} {'
  if [ "$TLS_MODE" = "cloudflare" ]; then
    echo '	# сертификат берём через DNS Cloudflare: не требует открытого 80 порта'
    echo '	tls {'
    echo '		dns cloudflare {env.CF_API_TOKEN}'
    echo '		resolvers 1.1.1.1 1.0.0.1'
    echo '	}'
  fi
  cat <<'EOF'
	reverse_proxy n8n:5678 {
		flush_interval -1
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {http.request.header.X-Forwarded-For}
	}

	request_body {
		max_size 1GB
	}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
}
EOF
} > "$DIR/caddy_config/Caddyfile"

# --- Dockerfile для Caddy с плагином Cloudflare ------------------------------
cat > "$DIR/caddy_build/Dockerfile" <<'EOF'
# Caddy со встроенным плагином DNS Cloudflare - нужен, чтобы получать
# сертификат через DNS, без открытого 80 порта.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF

# --- Мост socks5 -> http для контейнеров -------------------------------------
cat > "$DIR/proxy_bridge/Dockerfile" <<'EOF'
# n8n и Docker умеют только HTTP-прокси. Если у вас socks5, этот маленький
# контейнер принимает HTTP и отдаёт запросы дальше в ваш socks5.
FROM alpine:3.20
RUN apk add --no-cache tinyproxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8888
ENTRYPOINT ["/entrypoint.sh"]
EOF
cat > "$DIR/proxy_bridge/entrypoint.sh" <<'EOF'
#!/bin/sh
set -e
# UPSTREAM приходит из .env в виде socks5://[логин:пароль@]хост:порт
U="${UPSTREAM#socks5h://}"; U="${U#socks5://}"
CRED=""; HOSTPORT="$U"
case "$U" in *@*) CRED="${U%@*}"; HOSTPORT="${U##*@}" ;; esac
{
  echo "Port 8888"
  echo "Listen 0.0.0.0"
  echo "Allow 0.0.0.0/0"
  echo "LogLevel Warning"
  echo "ConnectPort 443"
  echo "ConnectPort 563"
  # ВАЖНО: без "*" в конце tinyproxy не разбирает адрес upstream (проверено)
  if [ -n "$CRED" ]; then
    echo "upstream socks5 ${CRED}@${HOSTPORT} \"*\""
  else
    echo "upstream socks5 ${HOSTPORT} \"*\""
  fi
} > /etc/tinyproxy/tinyproxy.conf
exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf
EOF
chmod 755 "$DIR/proxy_bridge/entrypoint.sh"

# --- docker-compose.yml ------------------------------------------------------
COMPOSE="$DIR/docker-compose.yml"
cat > "$COMPOSE" <<'EOF'
# n8n + PostgreSQL + Caddy. Наружу открыт только Caddy (80/443).
# Все пароли берутся из файла .env рядом с этим файлом.
# Файл создан установщиком - при повторном запуске он перезаписывается.

# Ограничиваем логи контейнеров: без этого они растут бесконечно
# и через несколько месяцев забивают диск.
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  postgres:
    logging: *logging
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_NON_ROOT_USER=${POSTGRES_NON_ROOT_USER}
      - POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_NON_ROOT_PASSWORD}
    volumes:
      - db_storage:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh:ro
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [n8n_net]

  n8n:
    logging: *logging
    image: docker.n8n.io/n8nio/n8n:${N8N_IMAGE_TAG:-latest}
    restart: unless-stopped
    environment:
      # --- адрес и работа через обратный прокси ---
      - N8N_HOST=${N8N_FQDN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${N8N_FQDN}/
      - N8N_WEBHOOK_URL=https://${N8N_FQDN}/
      - N8N_PROXY_HOPS=${N8N_PROXY_HOPS}
      - N8N_PUSH_BACKEND=${PUSH_BACKEND}
      - N8N_SECURE_COOKIE=true
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - TZ=${GENERIC_TIMEZONE}
      - NODE_ENV=production

      # --- база данных ---
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_NON_ROOT_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_NON_ROOT_PASSWORD}

      # --- ключ шифрования доступов ---
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

      # --- РЕЖИМ "ВСЁ ВКЛЮЧЕНО" ---
      - N8N_COMMUNITY_PACKAGES_ENABLED=true
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
      - N8N_COMMUNITY_PACKAGES_PREVENT_LOADING=false
      - N8N_UNVERIFIED_PACKAGES_ENABLED=true
      - N8N_VERIFIED_PACKAGES_ENABLED=true
      - N8N_REINSTALL_MISSING_PACKAGES=true
      - N8N_PYTHON_ENABLED=true
      # ни одна нода не отключена (в том числе Execute Command)
      - NODES_EXCLUDE=[]
      # доступ к переменным окружения прямо из нод
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      # в Code-ноде разрешены любые встроенные и внешние модули
      - NODE_FUNCTION_ALLOW_BUILTIN=*
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=false
      # максимальные размеры и лимиты
      - N8N_PAYLOAD_SIZE_MAX=1024
      - N8N_FORMDATA_FILE_SIZE_MAX=1024
      - EXECUTIONS_TIMEOUT=-1
      - EXECUTIONS_TIMEOUT_MAX=-1
      - N8N_CONCURRENCY_PRODUCTION_LIMIT=-1
      - N8N_RUNNERS_MAX_PAYLOAD=1073741824
      - N8N_RUNNERS_TASK_TIMEOUT=3600
      - N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES=2147483648
      - N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES=5000
      - NODE_OPTIONS=--max-old-space-size=${NODE_MEM_MB}
      - N8N_TEMPLATES_ENABLED=true

      # --- приватность ---
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
      - N8N_HIRING_BANNER_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=true

      # --- чтобы диск не забился историей запусков (год хранения) ---
      - N8N_DEFAULT_BINARY_DATA_MODE=filesystem
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=8760
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=200000
EOF

# прокси для нод n8n (и для установки community-нод через npm)
if [ -n "$CONTAINER_PROXY" ]; then
  cat >> "$COMPOSE" <<'EOF'

      # --- выход в интернет через ваш прокси ---
      # n8n читает эти переменные (пакет proxy-from-env), причём строчные
      # имеют приоритет над заглавными - задаём оба варианта одинаково.
      - HTTP_PROXY=${CONTAINER_PROXY}
      - HTTPS_PROXY=${CONTAINER_PROXY}
      - http_proxy=${CONTAINER_PROXY}
      - https_proxy=${CONTAINER_PROXY}
      - NO_PROXY=localhost,127.0.0.1,::1,postgres,n8n,caddy,proxy-bridge
      - no_proxy=localhost,127.0.0.1,::1,postgres,n8n,caddy,proxy-bridge
      # Node 24: без этого встроенный fetch прокси игнорирует
      - NODE_USE_ENV_PROXY=1
      # чтобы установка community-нод (npm) тоже шла через прокси
      - npm_config_proxy=${CONTAINER_PROXY}
      - npm_config_https_proxy=${CONTAINER_PROXY}
EOF
fi

cat >> "$COMPOSE" <<'EOF'
    volumes:
      - n8n_data:/home/node/.n8n
      - ${DATA_FOLDER}/local_files:/files
      - ${DATA_FOLDER}/workflows:/workflows:ro
    depends_on:
      postgres:
        condition: service_healthy
    networks: [n8n_net]

  caddy:
    logging: *logging
EOF

if [ "$TLS_MODE" = "cloudflare" ]; then
  cat >> "$COMPOSE" <<'EOF'
    # свой образ: штатный Caddy не умеет DNS Cloudflare
    build:
      context: ./caddy_build
    image: n8n-caddy-cloudflare:local
EOF
else
  echo "    image: caddy:2" >> "$COMPOSE"
fi

cat >> "$COMPOSE" <<'EOF'
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - N8N_FQDN=${N8N_FQDN}
      - SSL_EMAIL=${SSL_EMAIL}
EOF
[ "$TLS_MODE" = "cloudflare" ] && echo '      - CF_API_TOKEN=${CF_API_TOKEN}' >> "$COMPOSE"

cat >> "$COMPOSE" <<'EOF'
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ${DATA_FOLDER}/caddy_config/Caddyfile:/etc/caddy/Caddyfile:ro
    depends_on: [n8n]
    networks: [n8n_net]
EOF

if [ "$PROXY_KIND" = "socks5" ]; then
  cat >> "$COMPOSE" <<'EOF'

  # Мост: принимает HTTP от n8n и отправляет дальше в ваш socks5-прокси.
  proxy-bridge:
    logging: *logging
    build:
      context: ./proxy_bridge
    image: n8n-proxy-bridge:local
    restart: unless-stopped
    environment:
      - UPSTREAM=${PROXY_URL}
    networks: [n8n_net]
EOF
fi

cat >> "$COMPOSE" <<'EOF'

volumes:
  db_storage:
    name: n8n_db_storage
  n8n_data:
    name: n8n_data
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config

networks:
  n8n_net:
    driver: bridge
EOF
chmod 644 "$COMPOSE" "$DIR/caddy_config/Caddyfile"
ok "docker-compose.yml и Caddyfile созданы"

# --- backup.sh ---------------------------------------------------------------
cat > "$DIR/backup.sh" <<'EOF'
#!/usr/bin/env bash
# Резервная копия n8n: база данных + файлы + .env (в нём ключ шифрования).
# Запуск вручную:  /opt/n8n/backup.sh
set -Eeuo pipefail
DIR=/opt/n8n
OUT="$DIR/backups"
KEEP=14
STAMP="$(date +%F_%H-%M)"
mkdir -p "$OUT"
cd "$DIR"

fail() { echo "$1"; "$DIR/notify.sh" "Не удалось сделать резервную копию n8n

$1

Проверьте место на диске (df -h) и логи."; exit 1; }

echo "Делаем копию базы данных..."
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip > "$OUT/db-$STAMP.sql.gz" || fail "Не получилось выгрузить базу данных."
[ -s "$OUT/db-$STAMP.sql.gz" ] || fail "Файл копии базы получился пустым."

echo "Делаем копию файлов n8n..."
docker run --rm -v n8n_data:/data -v "$OUT":/backup alpine \
  tar czf "/backup/files-$STAMP.tar.gz" -C /data . >/dev/null

cp "$DIR/.env" "$OUT/env-$STAMP.txt"
chmod 600 "$OUT"/*

ls -1t "$OUT"/db-*.sql.gz    2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -1t "$OUT"/files-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -1t "$OUT"/env-*.txt      2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f

# заканчивается место - предупреждаем заранее, пока не поздно
USED=$(df -P "$DIR" | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ "${USED:-0}" -ge 85 ]; then
  echo "ВНИМАНИЕ: диск занят на ${USED}%"
  "$DIR/notify.sh" "На сервере с n8n заканчивается место: занято ${USED}%

Что можно сделать:
  - скачать и удалить старые копии из /opt/n8n/backups
  - освободить место:  docker system prune -a
  - увеличить диск у провайдера"
fi

echo "Готово. Копии лежат в $OUT"
echo "ВАЖНО: скачайте их себе на компьютер - копия на том же сервере не спасёт, если сервер пропадёт."
ls -lh "$OUT" | tail -n 6
EOF
chmod +x "$DIR/backup.sh"

# --- update.sh ---------------------------------------------------------------
cat > "$DIR/update.sh" <<'EOF'
#!/usr/bin/env bash
# Обновление n8n вручную. Делает то же, что ночное автообновление:
# копия -> обновление -> проверка -> откат, если не поднялось.
exec /opt/n8n/autoupdate.sh --force
EOF
chmod +x "$DIR/update.sh"

# --- autoupdate.sh -----------------------------------------------------------
cat > "$DIR/autoupdate.sh" <<'EOF'
#!/usr/bin/env bash
# Автообновление n8n с проверкой и откатом.
# Логика: есть ли новая версия -> копия -> обновление -> проверка ->
# если не поднялось, вернуть как было.
# Запускается по ночам из cron. Вручную:  /opt/n8n/autoupdate.sh --force
set -Eeuo pipefail
DIR=/opt/n8n
LOG=/var/log/n8n-update.log
ALERT="$DIR/ОБНОВЛЕНИЕ-НЕ-УДАЛОСЬ.txt"
FORCE="${1:-}"
cd "$DIR"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

version_now() { docker compose exec -T n8n n8n --version 2>/dev/null | tr -d '\r' | tail -n1; }

wait_healthy() { # wait_healthy СЕКУНД
  local limit="$1" waited=0
  while [ "$waited" -lt "$limit" ]; do
    if docker compose exec -T -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= n8n wget -qO- http://localhost:5678/healthz/readiness 2>/dev/null | grep -q '"ok"'; then
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

TAG="$(grep '^N8N_IMAGE_TAG=' .env | cut -d= -f2-)"; TAG="${TAG:-latest}"
IMG="docker.n8n.io/n8nio/n8n:$TAG"

# Если прошлое обновление откатилось - больше не трогаем, ждём человека.
if [ "$TAG" = "rollback" ]; then
  log "автообновление на паузе: прошлый раз пришлось откатиться. Смотрите $ALERT"
  exit 0
fi

OLD_ID="$(docker image inspect --format '{{.Id}}' "$IMG" 2>/dev/null || echo none)"
OLD_VER="$(version_now || echo '?')"

log "проверяем обновления (сейчас версия ${OLD_VER:-?})"
docker pull -q "$IMG" >/dev/null 2>&1 || { log "не удалось проверить обновления (нет связи?) - пропускаем"; exit 0; }
NEW_ID="$(docker image inspect --format '{{.Id}}' "$IMG")"

if [ "$OLD_ID" = "$NEW_ID" ] && [ "$FORCE" != "--force" ]; then
  log "новой версии нет, всё оставляем как есть"
  exit 0
fi

# Пока идём - сторож должен молчать: перезапуск n8n это не авария
touch "$DIR/.update-in-progress"
trap 'rm -f "$DIR/.update-in-progress"' EXIT

log "есть новая версия - делаем резервную копию перед обновлением"
"$DIR/backup.sh" >/dev/null 2>&1 || { log "копия не сделалась - обновление отменено"; exit 1; }
LAST_DB="$(ls -1t "$DIR"/backups/db-*.sql.gz 2>/dev/null | head -n1)"

log "обновляем n8n"
docker compose up -d n8n >/dev/null 2>&1

if wait_healthy 300; then
  NEW_VER="$(version_now)"
  log "готово, n8n работает. Версия: $NEW_VER"
  "$DIR/notify.sh" "n8n обновлён: $OLD_VER -> $NEW_VER
Всё поднялось и работает. Копия перед обновлением сохранена."
  docker image prune -f >/dev/null 2>&1 || true
  rm -f "$ALERT"
  exit 0
fi

# --- не поднялось: возвращаем прежний образ ---------------------------------
# Дальше идём до конца, что бы ни случилось: файл-предупреждение должен
# появиться в любом случае, иначе человек не узнает о проблеме.
set +e
log "ПОСЛЕ ОБНОВЛЕНИЯ n8n НЕ ЗАПУСТИЛСЯ - возвращаем прежнюю версию"
if [ "$OLD_ID" != "none" ]; then
  docker tag "$OLD_ID" "docker.n8n.io/n8nio/n8n:rollback"
  sed -i 's|^N8N_IMAGE_TAG=.*|N8N_IMAGE_TAG=rollback|' .env
  docker compose up -d n8n >/dev/null 2>&1
  if wait_healthy 180; then
    log "вернули прежнюю версию ($OLD_VER), n8n снова работает"
  else
    # Новая версия успела изменить базу - возвращаем и её
    log "прежней версии мало - восстанавливаем базу из копии перед обновлением"
    if [ -n "$LAST_DB" ]; then
      docker compose stop n8n >/dev/null 2>&1
      docker compose exec -T postgres sh -c 'psql -q -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_NON_ROOT_USER\";"' >/dev/null 2>&1
      gunzip -c "$LAST_DB" | docker compose exec -T postgres sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1
      docker compose up -d n8n >/dev/null 2>&1
      wait_healthy 180 && log "восстановили из копии, n8n работает" || log "восстановить не удалось - нужна помощь человека"
    fi
  fi
else
  log "прежнего образа нет - откатывать нечего, нужна помощь человека"
fi

cat > "$ALERT" <<TXT
Обновление n8n не удалось, $(date '+%d.%m.%Y %H:%M')

Новая версия n8n не запустилась, поэтому мы вернули ту, что работала раньше:
  $OLD_VER

Ваши сценарии и доступы на месте. Автообновление поставлено на паузу,
чтобы оно не повторяло ту же ошибку каждую ночь.

Что делать:
  1. Проверьте, что сайт открывается и всё работает.
  2. Посмотрите, что случилось:   tail -50 $LOG
  3. Когда захотите попробовать снова, верните обычную версию:
       sed -i 's|^N8N_IMAGE_TAG=.*|N8N_IMAGE_TAG=latest|' $DIR/.env
       $DIR/autoupdate.sh --force
  4. Копии на случай отката лежат в $DIR/backups
TXT
"$DIR/notify.sh" "Обновление n8n не удалось

Новая версия не запустилась, поэтому вернули прежнюю: $OLD_VER
Сценарии и доступы на месте, сайт работает.

Автообновление поставлено на паузу, чтобы не повторять ошибку каждую ночь.
Подробности на сервере: /opt/n8n/ОБНОВЛЕНИЕ-НЕ-УДАЛОСЬ.txt"
log "подробности записаны в $ALERT"
exit 1
EOF
chmod +x "$DIR/autoupdate.sh"

# --- готовые воркфлоу -------------------------------------------------------
# Кладём файлы и заводим импорт, который сработает сам, как только человек
# создаст учётную запись владельца: до этого момента n8n не к кому их привязать.
mkdir -p "$DIR/workflows"
WF_BASE="https://raw.githubusercontent.com/generalovai/n8n-install/main/workflows"
WF_LIST="01-proverka-servera.json 02-vitrina-uzlov.json 03-uzly-v-rabote.json"
# shellcheck disable=SC2086
for wf in $WF_LIST; do
  pcurl -fsSL --max-time 60 "$WF_BASE/$wf" -o "$DIR/workflows/$wf" 2>/dev/null \
    || warn "Не удалось скачать готовый воркфлоу $wf - не страшно, всё остальное работает"
done
chmod 644 "$DIR"/workflows/*.json 2>/dev/null || true

cat > "$DIR/import-workflows.sh" <<'EOF'
#!/usr/bin/env bash
# Кладёт готовые воркфлоу в n8n. Пока владелец не создан, привязывать их не к кому,
# поэтому скрипт молча ждёт и пробует снова - его запускает cron раз в 5 минут.
set -uo pipefail
DIR=/opt/n8n
DONE="$DIR/.workflows-imported"
cd "$DIR" || exit 0
[ -f "$DONE" ] && exit 0
ls "$DIR"/workflows/*.json >/dev/null 2>&1 || exit 0

OWNER="$(docker compose exec -T postgres psql -U postgres -d n8n -tAc \
  'select id from "user" where email is not null order by "createdAt" limit 1' 2>/dev/null | tr -d '\r ')"
[ -n "$OWNER" ] || exit 0        # аккаунт ещё не создан - подождём

for f in "$DIR"/workflows/*.json; do
  docker compose exec -T n8n n8n import:workflow \
    --input="/files/../workflows/$(basename "$f")" --userId="$OWNER" >/dev/null 2>&1 \
  || docker compose exec -T n8n n8n import:workflow \
    --input="/workflows/$(basename "$f")" --userId="$OWNER" >/dev/null 2>&1 || true
done

touch "$DONE"
rm -f /etc/cron.d/n8n-workflows
"$DIR/notify.sh" "В вашем n8n появились готовые воркфлоу

Откройте список - там есть «Проверка сервера». Запустите его кнопкой
Test workflow: он покажет, до каких сервисов дотягивается ваш n8n
и с какого адреса он выходит в интернет. Ключи для этого не нужны."
EOF
chmod +x "$DIR/import-workflows.sh"

cat > /etc/cron.d/n8n-workflows <<'EOF'
# Разложить готовые воркфлоу, как только появится учётная запись владельца.
# Задание убирает само себя, когда справится.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /opt/n8n/import-workflows.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/n8n-workflows
ok "Три готовых воркфлоу появятся сразу после создания учётной записи"

# --- notify.sh ---------------------------------------------------------------
cat > "$DIR/notify.sh" <<'EOF'
#!/usr/bin/env bash
# Отправляет сообщение в Telegram, если уведомления настроены.
# Если нет - молча выходит. Никогда не мешает работе того, кто её вызвал.
DIR=/opt/n8n
TOKEN="$(grep '^TG_TOKEN=' "$DIR/.env" 2>/dev/null | cut -d= -f2- | sed 's/\$\$/$/g')"
CHAT="$(grep '^TG_CHAT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
[ -n "$TOKEN" ] && [ -n "$CHAT" ] || exit 0
curl -sS --max-time 20 -o /dev/null \
  "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT}" \
  --data-urlencode "text=$1" \
  --data "disable_web_page_preview=true" 2>/dev/null || true
EOF
chmod +x "$DIR/notify.sh"

# --- watch.sh: сторож, замечает что n8n перестал отвечать --------------------
cat > "$DIR/watch.sh" <<'EOF'
#!/usr/bin/env bash
# Раз в 10 минут проверяет, жив ли n8n. Сообщает один раз, когда он лёг,
# и один раз, когда снова заработал. Пока всё хорошо - молчит.
set -uo pipefail
DIR=/opt/n8n
STATE="$DIR/.watch-state"     # о чём уже сообщили: up или down
FAILS="$DIR/.watch-fails"     # сколько проверок подряд не ответил
LOCK="$DIR/.update-in-progress"
LOG=/var/log/n8n-watch.log
cd "$DIR" || exit 0

# Во время обновления n8n перезапускается - это не авария, молчим.
[ -f "$LOCK" ] && exit 0

FQDN="$(grep '^N8N_FQDN=' .env | cut -d= -f2-)"
WAS="$(cat "$STATE" 2>/dev/null || echo up)"
N="$(cat "$FAILS" 2>/dev/null || echo 0)"

if docker compose exec -T -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= n8n wget -qO- --timeout=15 http://localhost:5678/healthz 2>/dev/null | grep -q '"ok"'; then
  echo 0 > "$FAILS"
  if [ "$WAS" = "down" ]; then
    printf '%s  снова работает\n' "$(date '+%F %T')" >> "$LOG"
    "$DIR/notify.sh" "n8n снова работает
Адрес: https://$FQDN"
    echo up > "$STATE"
  fi
  exit 0
fi

# Не ответил. Одна осечка - не повод будить человека: n8n мог
# перезапускаться. Сообщаем только со второй проверки подряд, то есть
# когда он недоступен уже минут двадцать.
N=$((N + 1)); echo "$N" > "$FAILS"
if [ "$N" -ge 2 ] && [ "$WAS" != "down" ]; then
  printf '%s  не отвечает (проверок подряд: %s)\n' "$(date '+%F %T')" "$N" >> "$LOG"
  "$DIR/notify.sh" "n8n не отвечает уже минут двадцать
Адрес: https://$FQDN

Сервер пробует поднять его сам. Если сообщения о восстановлении не будет,
зайдите и посмотрите:  cd /opt/n8n && docker compose logs --tail 50 n8n"
  echo down > "$STATE"
fi
EOF
chmod +x "$DIR/watch.sh"

# --- diagnose.sh -------------------------------------------------------------
cat > "$DIR/diagnose.sh" <<'EOF'
#!/usr/bin/env bash
# Собирает отчёт о состоянии сервера, который можно отправить в поддержку.
# Пароли, ключи и токены в отчёт НЕ попадают - можно показывать кому угодно.
set -uo pipefail
DIR=/opt/n8n
OUT="$DIR/diagnose.txt"
cd "$DIR" 2>/dev/null || { echo "n8n не установлен в $DIR"; exit 1; }

g() { grep "^$1=" .env 2>/dev/null | cut -d= -f2-; }

{
  echo "=== ОТЧЁТ О СОСТОЯНИИ n8n ==="
  echo "дата:              $(date '+%F %T %Z')"
  echo "версия установщика: $(g INSTALLER_VERSION)"
  echo "адрес:             $(g N8N_FQDN)"
  echo "способ сертификата: $(g TLS_MODE)   оранжевое облако: $(g CF_PROXIED)"
  echo "прокси:            $(g PROXY_KIND)"
  echo "автообновление:    $(g AUTO_UPDATE)   тег образа: $(g N8N_IMAGE_TAG)"
  echo "уведомления:       $([ -n "$(g TG_CHAT)" ] && echo настроены || echo нет)"

  echo
  echo "=== СЕРВЕР ==="
  . /etc/os-release 2>/dev/null && echo "система: ${PRETTY_NAME:-?}"
  echo "ядер: $(nproc 2>/dev/null)   память: $(awk '/MemTotal/{print int($2/1024)" МБ"}' /proc/meminfo)"
  echo "swap: $(swapon --show --noheadings 2>/dev/null | wc -l) файл(ов)"
  df -P -h / | awk 'NR==2 {print "диск: занято "$5" из "$2}'
  echo "docker: $(docker --version 2>/dev/null)"
  echo "compose: $(docker compose version --short 2>/dev/null)"

  echo
  echo "=== КОНТЕЙНЕРЫ ==="
  docker compose ps 2>&1

  echo
  echo "=== n8n ==="
  echo "версия: $(docker compose exec -T n8n n8n --version 2>/dev/null | tr -d '\r')"
  echo "внутренняя проверка: $(docker compose exec -T -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= n8n wget -qO- http://localhost:5678/healthz/readiness 2>/dev/null)"
  echo "снаружи по адресу:   $(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$(g N8N_FQDN)/healthz" 2>/dev/null)"
  echo "сертификат: $(docker compose logs caddy 2>/dev/null | grep -c 'certificate obtained') раз(а) получен"

  echo
  echo "=== ОШИБКИ В ЖУРНАЛЕ n8n (последние) ==="
  docker compose logs --tail 400 n8n 2>/dev/null | grep -iE 'error|fatal|cannot|refused|denied' | tail -15 || echo "(нет)"

  echo
  echo "=== ОШИБКИ CADDY (последние) ==="
  docker compose logs --tail 200 caddy 2>/dev/null | grep -i 'error' | tail -8 || echo "(нет)"

  echo
  echo "=== ОБНОВЛЕНИЯ ==="
  tail -12 /var/log/n8n-update.log 2>/dev/null || echo "(журнала нет)"
  [ -f "$DIR/ОБНОВЛЕНИЕ-НЕ-УДАЛОСЬ.txt" ] && echo "!!! есть файл ОБНОВЛЕНИЕ-НЕ-УДАЛОСЬ.txt"

  echo
  echo "=== СТОРОЖ ==="
  tail -8 /var/log/n8n-watch.log 2>/dev/null || echo "(журнала нет)"

  echo
  echo "=== РЕЗЕРВНЫЕ КОПИИ ==="
  ls -lh backups 2>/dev/null | tail -8 || echo "(копий нет)"

  echo
  echo "=== ЗАДАНИЯ ПО РАСПИСАНИЮ ==="
  for f in /etc/cron.d/n8n-*; do [ -e "$f" ] && basename "$f"; done 2>/dev/null || echo "(нет)"
} > "$OUT" 2>&1

# Подстраховка: вычищаем всё, что похоже на секрет, даже если оно случайно попало
sed -i -E 's/([A-Za-z_]*(TOKEN|PASSWORD|KEY|SECRET)[A-Za-z_]*=)[^ ]*/\1<скрыто>/g' "$OUT"

cat "$OUT"
echo
echo "-----------------------------------------------------------"
echo "Отчёт сохранён: $OUT"
echo "В нём нет паролей и ключей - можно спокойно переслать за помощью."
EOF
chmod +x "$DIR/diagnose.sh"

# --- report.sh: раз в месяц короткая сводка (заодно проверка, что связь жива) --
cat > "$DIR/report.sh" <<'EOF'
#!/usr/bin/env bash
# Раз в месяц присылает короткую сводку. Заодно это проверка того,
# что уведомления вообще доходят - молчащий канал не отличить от сломанного.
set -uo pipefail
DIR=/opt/n8n
cd "$DIR" || exit 0
FQDN="$(grep '^N8N_FQDN=' .env | cut -d= -f2-)"
VER="$(docker compose exec -T n8n n8n --version 2>/dev/null | tr -d '\r')"
DISK="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
COPIES="$(ls -1 "$DIR"/backups/db-*.sql.gz 2>/dev/null | wc -l | tr -d ' ')"
LAST="$(ls -1t "$DIR"/backups/db-*.sql.gz 2>/dev/null | head -1 | sed 's|.*/db-||; s|\.sql\.gz||')"
"$DIR/notify.sh" "Ежемесячная сводка по n8n

Адрес: https://$FQDN
Версия: ${VER:-неизвестно}
Диск занят: ${DISK}%
Резервных копий: ${COPIES}, последняя ${LAST:-нет}

Это сообщение приходит раз в месяц. Если оно перестало приходить -
значит уведомления сломались, стоит проверить."
EOF
chmod +x "$DIR/report.sh"

# --- restore.sh --------------------------------------------------------------
cat > "$DIR/restore.sh" <<'EOF'
#!/usr/bin/env bash
# Восстановление n8n из резервной копии.
# Запуск:  /opt/n8n/restore.sh            (покажет список копий)
#          /opt/n8n/restore.sh 2026-08-07_03-30
set -Eeuo pipefail
DIR=/opt/n8n
OUT="$DIR/backups"
cd "$DIR"

if [ -z "${1:-}" ]; then
  echo "Доступные копии:"
  ls -1 "$OUT"/db-*.sql.gz 2>/dev/null | sed 's|.*/db-||; s|\.sql\.gz||' || echo "  (копий нет)"
  echo
  echo "Запустите:  $0 <дата_время из списка>"
  exit 0
fi

STAMP="$1"
DB="$OUT/db-$STAMP.sql.gz"
FILES="$OUT/files-$STAMP.tar.gz"
[ -f "$DB" ] || { echo "Нет файла $DB"; exit 1; }

# Сначала убеждаемся, что копия целая. Иначе можно снести рабочую базу
# и остаться ни с чем - архив мог оборваться, например из-за нехватки места.
echo "Проверяем, что копия не повреждена..."
gunzip -t "$DB" 2>/dev/null || {
  echo
  echo "Файл копии базы повреждён: $DB"
  echo "Восстановление отменено, ваши текущие данные не тронуты."
  echo "Возьмите другую копию из списка:  $0"
  exit 1
}
if [ -f "$FILES" ]; then
  tar tzf "$FILES" >/dev/null 2>&1 || {
    echo
    echo "Файл копии с файлами повреждён: $FILES"
    echo "Восстановление отменено, ваши текущие данные не тронуты."
    exit 1
  }
fi
echo "Копия целая."

echo
echo "ВНИМАНИЕ: текущие данные n8n будут заменены копией от $STAMP."
read -r -p "Продолжить? Напишите yes: " a
[ "$a" = "yes" ] || { echo "Отменено."; exit 0; }

echo "Проверяем ключ шифрования..."
if [ -f "$OUT/env-$STAMP.txt" ]; then
  OLD_KEY="$(grep '^N8N_ENCRYPTION_KEY=' "$OUT/env-$STAMP.txt" | cut -d= -f2-)"
  NOW_KEY="$(grep '^N8N_ENCRYPTION_KEY=' "$DIR/.env" | cut -d= -f2-)"
  if [ "$OLD_KEY" != "$NOW_KEY" ]; then
    echo "Ключ шифрования отличается от того, что был при создании копии."
    echo "Подставляем ключ из копии, иначе доступы не расшифруются."
    sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$OLD_KEY|" "$DIR/.env"
  fi
fi

echo "Останавливаем n8n..."
docker compose stop n8n

docker compose up -d postgres
sleep 10

# Страховка: сохраняем то, что есть сейчас, - вдруг восстановились не в ту копию
SAFETY="$OUT/before-restore-$(date +%F_%H-%M).sql.gz"
echo "На всякий случай сохраняем текущее состояние в $SAFETY ..."
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip > "$SAFETY" || echo "  (не получилось - видимо, базы ещё нет, это нормально)"

echo "Восстанавливаем базу данных..."
docker compose exec -T postgres sh -c 'psql -q -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_NON_ROOT_USER\";"'
gunzip -c "$DB" | docker compose exec -T postgres sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

if [ -f "$FILES" ]; then
  echo "Восстанавливаем файлы n8n..."
  docker run --rm -v n8n_data:/data -v "$OUT":/backup alpine \
    sh -c "rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /backup/files-$STAMP.tar.gz -C /data"
fi

echo "Запускаем..."
docker compose up -d --remove-orphans
sleep 10
docker compose ps
echo "Готово. Откройте свой адрес в браузере и проверьте, что сценарии на месте."
EOF
chmod +x "$DIR/restore.sh"
ok "Созданы скрипты backup.sh, update.sh и restore.sh"

# Логи установщика и бэкапа тоже не должны расти бесконечно
cat > /etc/logrotate.d/n8n <<'EOF'
/var/log/n8n-install.log /var/log/n8n-backup.log /var/log/n8n-update.log /var/log/n8n-watch.log {
	monthly
	rotate 6
	compress
	missingok
	notifempty
	copytruncate
}
EOF
chmod 644 /etc/logrotate.d/n8n

if [ ! -f /etc/cron.d/n8n-backup ]; then
  cat > /etc/cron.d/n8n-backup <<'EOF'
# Ежедневная резервная копия n8n в 02:00 (по времени сервера)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /opt/n8n/backup.sh >> /var/log/n8n-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/n8n-backup
fi
ok "Ежедневная резервная копия настроена (каждую ночь в 02:00)"

if [ -n "$TG_CHAT" ]; then
  cat > /etc/cron.d/n8n-watch <<'EOF'
# Каждые 10 минут проверяем, отвечает ли n8n (сообщение только при изменении)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root /opt/n8n/watch.sh >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/n8n-watch
  cat > /etc/cron.d/n8n-report <<'EOF'
# Первого числа в 9 утра - короткая сводка (и проверка, что уведомления живы)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 9 1 * * root /opt/n8n/report.sh >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/n8n-report
  ok "Сторож включён: сообщит, если n8n перестанет отвечать"
else
  rm -f /etc/cron.d/n8n-watch /etc/cron.d/n8n-report
fi

if [ "$AUTO_UPDATE" = "да" ]; then
  cat > /etc/cron.d/n8n-update <<'EOF'
# Проверка обновлений n8n в 03:00 - после ночной копии.
# Перед самим обновлением скрипт делает ещё одну, свежую.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /opt/n8n/autoupdate.sh >> /var/log/n8n-update.log 2>&1
EOF
  chmod 644 /etc/cron.d/n8n-update
  ok "Автообновление включено (проверка каждую ночь в 03:00, после копии)"
else
  rm -f /etc/cron.d/n8n-update
  ok "Автообновление выключено - обновлять командой /opt/n8n/update.sh"
fi

# ---------- 10. запуск --------------------------------------------------------
step "Шаг 10 из 10. Запускаем n8n"

if [ "$TLS_MODE" = "cloudflare" ] || [ "$PROXY_KIND" = "socks5" ]; then
  info "Собираем нужные образы. Первый раз это долго - до 5 минут, дальше быстро..."
  dc build --quiet 2>/dev/null || dc build \
    || die "Не удалось собрать образ.
Если сервер в России - скорее всего не открылись сайты Docker или Go.
Вернитесь на шаг 2 и укажите рабочий прокси, затем запустите скрипт заново."
  ok "Образы собраны"
fi

info "Скачиваем образы (самая долгая часть, 1-4 минуты)..."
# Собираемые локально образы (caddy для Cloudflare, мост socks5) пропускаем:
# в реестре их нет, и pull на них падает.
PULL_SERVICES="postgres n8n"
[ "$TLS_MODE" = "cloudflare" ] || PULL_SERVICES="$PULL_SERVICES caddy"
# shellcheck disable=SC2086
dc pull -q $PULL_SERVICES 2>/dev/null || dc pull $PULL_SERVICES || die "Не удалось скачать образы Docker.
Если сервер в России - вернитесь на шаг 2 и укажите прокси:
именно через него Docker будет качать образы."

info "Стартуем..."
# --remove-orphans убирает контейнеры, которые больше не нужны:
# например, мост socks5, если человек сменил прокси на обычный
dc up -d --remove-orphans

# ВАЖНО: прокси для этой проверки гасим. wget внутри контейнера уважает
# http_proxy и пойдёт спрашивать про localhost у зарубежного прокси,
# а тот ответит 403 - проверка провалится при живом n8n (проверено вживую).
info "Ждём, пока n8n поднимется..."
UP=нет
for _ in $(seq 1 60); do
  if dc exec -T -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= n8n wget -qO- http://localhost:5678/healthz 2>/dev/null | grep -q '"ok"'; then
    UP=да; break
  fi
  sleep 5
done

if [ "$UP" != "да" ]; then
  say ""; dc ps || true
  say ""; say "Последние строки журнала n8n:"; dc logs --tail 30 n8n || true
  die "n8n не запустился за 5 минут. Выше видно, что случилось.
Частые причины: мало оперативной памяти или база данных не поднялась.
Попробуйте запустить установщик ещё раз - данные не потеряются."
fi
ok "n8n работает внутри сервера"

# --- проверка HTTPS ----------------------------------------------------------
info "Ждём HTTPS-сертификат (обычно 20-90 секунд)..."
TLS=нет
for _ in $(seq 1 30); do
  if curl -fsS --max-time 10 "https://$FQDN/healthz" 2>/dev/null | grep -q '"ok"'; then
    TLS=да; break
  fi
  sleep 10
done

if [ "$TLS" = "да" ]; then
  ok "HTTPS работает: https://$FQDN"
else
  warn "Сертификат пока не выдан. n8n при этом работает - дело только в сертификате."
  if [ "$TLS_MODE" = "cloudflare" ]; then
    say "  Проверьте, что у токена есть права Zone:DNS:Edit именно на этот домен."
  else
    say "  Обычные причины:"
    say "    - A-запись ещё не разошлась (подождите 10-30 минут, Caddy получит сертификат сам);"
    say "    - провайдер закрыл порт 80. Тогда перезапустите установщик и выберите"
    say "      вариант с Cloudflare - там сертификат выдаётся через DNS, без 80 порта."
  fi
  say "  Посмотреть, что происходит:  cd $DIR && docker compose logs caddy | tail -30"
fi

# --- живая проверка прокси: реально ли n8n выходит через него ----------------
PROXY_OK=""
if [ -n "$CONTAINER_PROXY" ]; then
  info "Проверяем, что n8n выходит в интернет через ваш прокси..."
  PROXY_OK="$(dc exec -T n8n node -e "fetch('https://api.ipify.org').then(r=>r.text()).then(t=>console.log(t.trim())).catch(()=>{})" 2>/dev/null | tail -n1 | tr -dc '0-9.:a-fA-F')"
  if [ -n "$PROXY_OK" ] && [ "$PROXY_OK" != "$SERVER_IP" ]; then
    ok "Прокси работает: наружу n8n выходит с адреса $PROXY_OK (а не $SERVER_IP)"
  elif [ "$PROXY_OK" = "$SERVER_IP" ]; then
    warn "n8n выходит в интернет НАПРЯМУЮ (адрес $PROXY_OK), прокси не применился."
    say  "  Проверьте адрес прокси в $ENV_FILE и перезапустите:  cd $DIR && docker compose up -d"
  else
    warn "Не удалось проверить прокси - интернет из контейнера n8n не отвечает."
    say  "  Посмотрите логи:  cd $DIR && docker compose logs proxy-bridge n8n | tail -30"
  fi
fi

tg_send "n8n установлен и работает

Адрес: https://$FQDN

Откройте ссылку и создайте учётную запись владельца - прямо сейчас, пока это
не сделал кто-то другой.

Ключ шифрования (сохраните, без него не восстановить доступы):
$N8N_ENCRYPTION_KEY"

# ---------- итог -------------------------------------------------------------
say ""
printf '%s' "$GREEN"
cat <<'TXT'
  ============================================================
                    ГОТОВО! n8n установлен
  ============================================================
TXT
printf '%s' "$R"

cat <<TXT

  Ваш адрес:   ${B}https://$FQDN${R}

  Откройте эту ссылку в браузере и создайте учётную запись владельца.
  ${YEL}Сделайте это прямо сейчас: пока аккаунт не создан, любой,
  кто знает адрес, может занять ваш n8n.${R}

TXT

printf '%s' "$RED"
cat <<'TXT'
  ############################################################
  #                                                          #
  #        КЛЮЧ ШИФРОВАНИЯ - СОХРАНИТЕ ЕГО ПРЯМО СЕЙЧАС      #
  #                                                          #
  ############################################################
TXT
printf '%s' "$R"
say ""
printf '        %s%s%s\n' "$B" "$N8N_ENCRYPTION_KEY" "$R"
say ""
cat <<TXT
  Этим ключом зашифрованы ВСЕ ваши доступы к сервисам
  (токены Telegram, ключи OpenAI, пароли к почте и так далее).

  Скопируйте его в заметки, менеджер паролей или отправьте себе.
  Без него восстановить n8n из резервной копии НЕВОЗМОЖНО.
  Ключ также лежит в файле $ENV_FILE

TXT
[ "$KEY_IS_NEW" = "нет" ] && say "  (Это тот же ключ, что был у прошлой установки.)"

if [ -n "$PROXY_URL" ]; then
cat <<TXT

  Прокси включён. Через него ходят и Docker (за образами),
  и сами ноды n8n (в OpenAI, Telegram и прочие сервисы).
  Проверить из n8n можно так: нода HTTP Request на адрес
  https://api.ipify.org - она должна показать IP прокси, а не сервера.

TXT
fi

cat <<TXT

  ------------------------------------------------------------
  Полезные команды (просто скопируйте в терминал сервера):

    Обновить n8n сейчас:     /opt/n8n/update.sh
    Сделать копию сейчас:    /opt/n8n/backup.sh
    Восстановить из копии:   /opt/n8n/restore.sh
    Отчёт для поддержки:     /opt/n8n/diagnose.sh
    Посмотреть, что не так:  cd /opt/n8n && docker compose logs -f n8n
    Перезапустить:           cd /opt/n8n && docker compose restart
    Остановить:              cd /opt/n8n && docker compose down
    Запустить снова:         cd /opt/n8n && docker compose up -d

  $([ "$AUTO_UPDATE" = "да" ] && echo "Каждую ночь в 03:00 n8n проверяет обновления и ставит их сам.
  Если новая версия не запустится, он вернёт прежнюю и напишет об этом
  в файл /opt/n8n/ОБНОВЛЕНИЕ-НЕ-УДАЛОСЬ.txt" || echo "Автообновление выключено.")

  Резервные копии создаются каждую ночь в 02:00 и лежат в
  /opt/n8n/backups (хранятся последние 14 штук).
  Иногда скачивайте их себе на компьютер.

  Лог установки: $LOG
  ------------------------------------------------------------

TXT
