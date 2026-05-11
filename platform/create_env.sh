#!/usr/bin/env bash
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/platform/lib.sh"

usage() { echo "Usage: $0 <name> [ttl_seconds]"; exit 1; }
[[ $# -lt 1 ]] && usage

ENV_NAME="$1"
TTL="${2:-1800}"   # default 30 min

# ── generate unique env ID ───────────────────────────────────────────────────
ENV_ID="env-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
NETWORK_NAME="sandbox-net-$ENV_ID"
CONTAINER_NAME="sandbox-app-$ENV_ID"
HOST_PORT=$(get_free_port)
CREATED_AT=$(date -u +%s)
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"

log_info "Creating environment '$ENV_NAME' (ID=$ENV_ID, TTL=${TTL}s, port=$HOST_PORT)"

# ── Docker network ────────────────────────────────────────────────────────────
docker network create "$NETWORK_NAME" >/dev/null
log_info "Network $NETWORK_NAME created"

# ── Start app container ───────────────────────────────────────────────────────
docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  -p "$HOST_PORT:8080" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  sandbox-demo-app >/dev/null

log_info "Container $CONTAINER_NAME started on port $HOST_PORT"

# ── Nginx config ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$NGINX_CONF")"
cat > "$NGINX_CONF" <<NGINX
# Auto-generated for env $ENV_ID — DO NOT EDIT MANUALLY
server {
    listen 80;
    server_name ${ENV_ID}.sandbox.local;

    location / {
        proxy_pass         http://host.docker.internal:${HOST_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 30s;
    }

    location /health {
        proxy_pass http://host.docker.internal:${HOST_PORT}/health;
    }
}
NGINX

reload_nginx
log_info "Nginx config written and reloaded"

# ── Log shipping (Approach A) ─────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
docker logs -f "$CONTAINER_NAME" >> "$LOG_DIR/app.log" 2>&1 &
LOG_PID=$!
log_info "Log shipping started (PID=$LOG_PID)"

# ── Write state file atomically ───────────────────────────────────────────────
TEMP_STATE=$(mktemp)
cat > "$TEMP_STATE" <<JSON
{
  "id":            "$ENV_ID",
  "name":          "$ENV_NAME",
  "created_at":    $CREATED_AT,
  "ttl":           $TTL,
  "status":        "running",
  "container":     "$CONTAINER_NAME",
  "network":       "$NETWORK_NAME",
  "host_port":     $HOST_PORT,
  "log_pid":       $LOG_PID,
  "nginx_conf":    "$NGINX_CONF",
  "consecutive_failures": 0
}
JSON
mv "$TEMP_STATE" "$STATE_FILE"
log_info "State written to $STATE_FILE"

# ── Done ──────────────────────────────────────────────────────────────────────
EXPIRE_AT=$(date -u -d "@$((CREATED_AT + TTL))" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
  || date -u -r "$((CREATED_AT + TTL))" '+%Y-%m-%d %H:%M:%S UTC')

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Environment Ready                                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  ID      : %-45s ║\n" "$ENV_ID"
printf "║  Name    : %-45s ║\n" "$ENV_NAME"
printf "║  URL     : %-45s ║\n" "http://localhost:$HOST_PORT"
printf "║  Nginx   : %-45s ║\n" "http://$ENV_ID.sandbox.local"
printf "║  Expires : %-45s ║\n" "$EXPIRE_AT"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
