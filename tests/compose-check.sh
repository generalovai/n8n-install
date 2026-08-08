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

for mode in plain cloudflare; do
  D="$WORK/$mode"; mkdir -p "$D"
  if [ "$mode" = plain ]; then
    gen "$D" 'n8n.mysite.ru\nн\nн\nadmin@m.ru\nEurope/Moscow\nд\nн\n'
  else
    gen "$D" 'n8n.example.ru\nд\nsocks5://u:secret@1.2.3.4:1080\nд\ntoken123\nд\nadmin@e.ru\nEurope/Moscow\nд\nн\n'
  fi
  ( cd "$D" && docker compose --project-directory . config --quiet ) \
    && echo "  режим $mode: compose валиден"
  docker run --rm -e CF_API_TOKEN=aBcDeF1234567890aBcDeF1234567890aBcDeF12 \
    -e N8N_FQDN=n8n.example.ru -e SSL_EMAIL=a@b.ru \
    -v "$D/caddy_config/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile 2>&1 | grep -q 'Valid configuration' \
    && echo "  режим $mode: Caddyfile валиден" \
    || echo "  режим $mode: Caddyfile проверить не удалось (для Cloudflare нужен образ с плагином)"
done
rm -rf "$WORK"
