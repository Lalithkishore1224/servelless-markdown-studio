#!/bin/bash
# Expose the app port via a Cloudflare quick tunnel and publish the public URL
# back to the repo so the Servelless server can read it (raw.githubusercontent).
set -u

PORT="${1:?usage: servelless-tunnel.sh <port>}"
REPO="${GITHUB_REPOSITORY:-}"
TOKEN="${GITHUB_TOKEN:-}"
NAME="${CODESPACE_NAME:-}"
WS="/workspaces/$(basename "${REPO:-repo}")"
TUN="$HOME/.servelless"

if [ -z "$REPO" ] || [ -z "$TOKEN" ] || [ -z "$NAME" ]; then
  echo "missing env (GITHUB_REPOSITORY/GITHUB_TOKEN/CODESPACE_NAME)" >&2
  exit 0
fi

mkdir -p "$TUN"
CF="$TUN/cloudflared"
if [ ! -x "$CF" ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$CF" || {
    echo "cloudflared download failed" >&2
    exit 0
  }
  chmod +x "$CF"
fi

nohup "$CF" tunnel --url "http://localhost:$PORT" --no-autoupdate \
  --logfile "$TUN/tunnel.log" >/dev/null 2>&1 &

for i in $(seq 1 90); do
  URL=$(grep -oE 'https://[a-z0-9-]+[.]trycloudflare[.]com' "$TUN/tunnel.log" 2>/dev/null | head -1)
  if [ -n "$URL" ]; then
    mkdir -p "$WS/.servelless"
    printf '{"url":"%s","port":%s,"updated":"%s"}\n' "$URL" "$PORT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$WS/.servelless/tunnel-${NAME}.json"
    cd "$WS" || exit 0
    git config user.email "servelless@users.noreply.github.com" 2>/dev/null
    git config user.name "servelless" 2>/dev/null
    git add ".servelless/tunnel-${NAME}.json" 2>/dev/null
    git commit -m "chore: tunnel url" --allow-empty >/dev/null 2>&1
    BR=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
    for t in 1 2 3; do
      git push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "HEAD:$BR" >/dev/null 2>&1 && break
      sleep 5
    done
    break
  fi
  sleep 2
done

exit 0