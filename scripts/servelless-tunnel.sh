#!/bin/bash
# Expose the app port via a Cloudflare quick tunnel and publish the public URL
# back to the repo so the Servelless server can read it (raw.githubusercontent).
# Runs as a watchdog: keeps cloudflared alive and re-publishes if it restarts.
set -u

PORT="${1:?usage: servelless-tunnel.sh <port>}"
REPO="${GITHUB_REPOSITORY:-}"
TOKEN="${GITHUB_TOKEN:-}"
NAME="${CODESPACE_NAME:-}"
WS="/workspaces/$(basename "${REPO:-repo}")"
TUN="$HOME/.servelless"
CF="$TUN/cloudflared"

if [ -z "$REPO" ] || [ -z "$TOKEN" ] || [ -z "$NAME" ]; then
  echo "missing env (GITHUB_REPOSITORY/GITHUB_TOKEN/CODESPACE_NAME)" >&2
  exit 0
fi

mkdir -p "$TUN"
if [ ! -x "$CF" ]; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$CF" || {
    echo "cloudflared download failed" >&2
    exit 0
  }
  chmod +x "$CF"
fi

app_up() {
  curl -fsS -m 5 "http://127.0.0.1:$PORT/" >/dev/null 2>&1
}

cf_running() {
  pgrep -f "cloudflared tunnel --url http://127.0.0.1:$PORT" >/dev/null 2>&1
}

publish() {
  local url="$1"
  mkdir -p "$WS/.servelless"
  printf '{"url":"%s","port":%s,"updated":"%s"}\n' "$url" "$PORT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$WS/.servelless/tunnel-${NAME}.json"
  cd "$WS" || return
  git config user.email "servelless@users.noreply.github.com" 2>/dev/null
  git config user.name "servelless" 2>/dev/null
  git add ".servelless/tunnel-${NAME}.json" 2>/dev/null
  git commit -m "chore: tunnel url" --allow-empty >/dev/null 2>&1
  BR=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
  for t in 1 2 3; do
    git push "https://x-access-token:${TOKEN}@github.com/${REPO}.git" "HEAD:$BR" >/dev/null 2>&1 && break
    sleep 5
  done
}

while true; do
  # start cloudflared if not running
  if ! cf_running; then
    rm -f "$TUN/tunnel.log"
    nohup "$CF" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate \
      --logfile "$TUN/tunnel.log" >/dev/null 2>&1 &
  fi

  # wait for a tunnel URL
  URL=""
  for i in $(seq 1 90); do
    URL=$(grep -oE 'https://[a-z0-9-]+[.]trycloudflare[.]com' "$TUN/tunnel.log" 2>/dev/null | tail -1)
    [ -n "$URL" ] && break
    sleep 2
  done

  # wait for the app to respond, then publish
  for i in $(seq 1 60); do
    app_up && break
    sleep 2
  done

  if [ -n "$URL" ] && app_up; then
    publish "$URL"
  fi

  # monitor until the tunnel or the app drops, then loop to recover
  for i in $(seq 1 40); do
    if ! cf_running; then break; fi
    if ! app_up; then break; fi
    sleep 15
  done
  sleep 5
done