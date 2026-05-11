#!/usr/bin/env bash
# Auto-cleanup daemon — runs every 60 s, destroys expired environments
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/platform/lib.sh"

mkdir -p "$ROOT_DIR/logs"

_log_cleanup "Cleanup daemon started (PID=$$)"

while true; do
  NOW=$(date -u +%s)

  for STATE_FILE in "$ROOT_DIR/envs/"*.json; do
    [[ -f "$STATE_FILE" ]] || continue

    ENV_ID=$(jq -r '.id'         "$STATE_FILE")
    CREATED=$(jq -r '.created_at' "$STATE_FILE")
    TTL=$(jq     -r '.ttl'        "$STATE_FILE")
    STATUS=$(jq  -r '.status'     "$STATE_FILE")

    EXPIRE_AT=$((CREATED + TTL))

    if [[ "$NOW" -ge "$EXPIRE_AT" ]]; then
      _log_cleanup "ENV $ENV_ID expired (status=$STATUS) — destroying"
      bash "$ROOT_DIR/platform/destroy_env.sh" "$ENV_ID" \
        >> "$ROOT_DIR/logs/cleanup.log" 2>&1 \
        && _log_cleanup "ENV $ENV_ID destroyed successfully" \
        || _log_cleanup "ERROR destroying $ENV_ID — see logs above"
    fi
  done

  sleep 60
done
