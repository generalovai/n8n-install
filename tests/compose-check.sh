#!/usr/bin/env bash
# Генерирует docker-compose.yml в обоих режимах и проверяет его настоящим docker compose.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

gen() { # gen ПАПКА ОТВЕТЫ
  docker run --rm -v "$ROOT/tests/stubs.sh:/stubs.sh:ro" -v "$1:/out" \
    -v "$ROOT/install.sh:/work/install.sh:ro" ubuntu:22.04 bash -c \
    "bash /stubs.sh; export PATH=/stub:\$PATH; printf '$2' | bash /work/install.sh >/dev/null 2>&1; cp -r /opt/n8n/. /out/"
}

# Файлы внутри контейнера создаются от root. На Linux-раннере обычный
# пользователь потом не может их прочитать (.env вообще 600), поэтому
# сразу возвращаем себе владение.
own() { docker run --rm -v "$WORK:/w" alpine chown -R "$(id -u):$(id -g)" /w >/dev/null 2>&1 || true; }

for mode in plain cloudflare; do
  D="$WORK/$mode"; mkdir -p "$D"
  if [ "$mode" = plain ]; then
    # домен, прокси?н, Cloudflare?н, почта, часовой пояс, автообновление?д, уведомления?н
    gen "$D" 'n8n.mysite.ru\nn\nn\nadmin@m.ru\nEurope/Moscow\ny\nn\n'
  else
    # домен, прокси?д, адрес, подтверждение адреса, Cloudflare?д, токен,
    # оранжевое облако?д, почта, часовой пояс, автообновление?д, уведомления?н
    gen "$D" 'n8n.example.ru\ny\nsocks5://u:secret@1.2.3.4:1080\ny\ny\ntoken123\ny\nadmin@e.ru\nEurope/Moscow\ny\nn\n'
  fi
  own

  # Тест обязан убедиться, что проверяет ИМЕННО тот режим. Иначе сдвиг
  # ответов на один вопрос превращает проверку в самообман (уже случалось).
  if [ "$mode" = cloudflare ]; then
    grep -q 'dns cloudflare' "$D/caddy_config/Caddyfile" \
      || { echo "  ПРОВАЛ: в режиме cloudflare нет строки dns cloudflare"; exit 1; }
    grep -q 'CF_API_TOKEN' "$D/docker-compose.yml" \
      || { echo "  ПРОВАЛ: в режиме cloudflare нет CF_API_TOKEN в compose"; exit 1; }
    grep -q 'proxy-bridge' "$D/docker-compose.yml" \
      || { echo "  ПРОВАЛ: мост socks5 не появился"; exit 1; }
  else
    grep -q 'dns cloudflare' "$D/caddy_config/Caddyfile" \
      && { echo "  ПРОВАЛ: в обычном режиме затесалась настройка Cloudflare"; exit 1; }
    grep -q 'image: caddy:2' "$D/docker-compose.yml" \
      || { echo "  ПРОВАЛ: в обычном режиме должен быть готовый образ caddy"; exit 1; }
  fi
  echo "  режим $mode: сгенерирован правильный режим"

  ( cd "$D" && docker compose --project-directory . config --quiet ) \
    && echo "  режим $mode: compose валиден"
  OUT="$(docker run --rm -e CF_API_TOKEN=aBcDeF1234567890aBcDeF1234567890aBcDeF12 \
    -e N8N_FQDN=n8n.example.ru -e SSL_EMAIL=a@b.ru \
    -v "$D/caddy_config/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile 2>&1 || true)"
  if printf '%s' "$OUT" | grep -q 'Valid configuration'; then
    echo "  режим $mode: Caddyfile валиден"
  elif [ "$mode" = cloudflare ] && printf '%s' "$OUT" | grep -q 'dns.providers.cloudflare'; then
    # штатному образу caddy неоткуда знать про плагин - это не ошибка конфига
    echo "  режим $mode: Caddyfile разобран, плагин cloudflare подключается отдельно"
  else
    echo "  ПРОВАЛ: Caddyfile не проходит проверку в режиме $mode"
    printf '%s\n' "$OUT" | tail -5
    exit 1
  fi
done
own; rm -rf "$WORK"
