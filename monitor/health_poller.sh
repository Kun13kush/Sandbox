#!/usr/bin/env bash
# Health poller — checks every active env's /health endpoint every 30s
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/platform/lib.sh"

POLL_INTERVAL=30
FAILURE_THRESHOLD=3

log_info "Health monitor started (PID=$$, interval=${POLL_INTERVAL}s)"

while true; do
  for STATE_FILE in "$ROOT_DIR/envs/"*.json; do
    [[ -f "$STATE_FILE" ]] || continue

    ENV_ID=$(jq   -r '.id'        "$STATE_FILE")
    HOST_PORT=$(jq -r '.host_port' "$STATE_FILE")
    STATUS=$(jq   -r '.status'    "$STATE_FILE")
    FAILS=$(jq    -r '.consecutive_failures' "$STATE_FILE")

    # Skip non-running envs
    [[ "$STATUS" == "running" || "$STATUS" == "degraded" ]] || continue

    LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
    mkdir -p "$LOG_DIR"
    HEALTH_LOG="$LOG_DIR/health.log"

    URL="http://localhost:${HOST_PORT}/health"
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # curl: -s silent, -o /dev/null discard body, -w write timing
    RESULT=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" \
      --max-time 5 "$URL" 2>/dev/null || echo "000 0")

    HTTP_CODE=$(echo "$RESULT" | awk '{print $1}')
    LATENCY=$(echo  "$RESULT" | awk '{printf "%.3f", $2}')

    echo "$TS  status=$HTTP_CODE  latency=${LATENCY}s  env=$ENV_ID" >> "$HEALTH_LOG"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
      # Healthy — reset failure count
      if [[ "$FAILS" -gt 0 ]]; then
        update_state_key "$ENV_ID" "consecutive_failures" '0'
        update_state_key "$ENV_ID" "status" '"running"'
      fi
    else
      FAILS=$((FAILS + 1))
      update_state_key "$ENV_ID" "consecutive_failures" "$FAILS"

      if [[ "$FAILS" -ge "$FAILURE_THRESHOLD" ]]; then
        log_warn "⚠️  ENV $ENV_ID — $FAILS consecutive failures! Marking DEGRADED."
        update_state_key "$ENV_ID" "status" '"degraded"'
        echo "$TS  [ALERT] $ENV_ID marked degraded after $FAILS failures" >> "$HEALTH_LOG"
      fi
    fi
  done

  sleep "$POLL_INTERVAL"
done
