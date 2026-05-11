#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/platform/lib.sh"

usage() { echo "Usage: $0 <env_id>"; exit 1; }
[[ $# -lt 1 ]] && usage

ENV_ID="$1"
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"

[[ ! -f "$STATE_FILE" ]] && { log_error "No state file for $ENV_ID"; exit 1; }

# Read state
CONTAINER=$(jq -r '.container'  "$STATE_FILE")
NETWORK=$(jq  -r '.network'     "$STATE_FILE")
NGINX_CONF=$(jq -r '.nginx_conf' "$STATE_FILE")
LOG_PID=$(jq  -r '.log_pid'     "$STATE_FILE")
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"

log_info "Destroying environment $ENV_ID"

# ── Kill log shipping process ─────────────────────────────────────────────────
if [[ -n "$LOG_PID" && "$LOG_PID" != "null" ]]; then
  kill "$LOG_PID" 2>/dev/null && log_info "Log PID $LOG_PID killed" || true
fi

# ── Stop & remove containers ──────────────────────────────────────────────────
CONTAINERS=$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" 2>/dev/null || true)
if [[ -n "$CONTAINERS" ]]; then
  docker rm -f $CONTAINERS >/dev/null 2>&1 && log_info "Containers removed" || true
fi

# ── Remove Docker network ─────────────────────────────────────────────────────
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK}$" 2>/dev/null; then
  docker network rm "$NETWORK" >/dev/null 2>&1 && log_info "Network $NETWORK removed" || true
fi

# ── Remove Nginx config and reload ───────────────────────────────────────────
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  reload_nginx
  log_info "Nginx config removed and reloaded"
fi

# ── Archive logs ──────────────────────────────────────────────────────────────
if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  cp -r "$LOG_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true
  rm -rf "$LOG_DIR"
  log_info "Logs archived to $ARCHIVE_DIR"
fi

# ── Delete state file ─────────────────────────────────────────────────────────
rm -f "$STATE_FILE"
log_info "State file deleted"

echo "✅  Environment $ENV_ID destroyed successfully."
