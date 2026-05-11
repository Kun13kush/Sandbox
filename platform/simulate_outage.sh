#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/platform/lib.sh"

usage() {
  echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>"
  exit 1
}

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)   ENV_ID="$2"; shift 2 ;;
    --mode)  MODE="$2";   shift 2 ;;
    *)       usage ;;
  esac
done

[[ -z "$ENV_ID" || -z "$MODE" ]] && usage

# ── Safety guard — never target Nginx or the daemon container ─────────────────
PROTECTED_PATTERNS=("sandbox-nginx" "sandbox-daemon" "sandbox-api")
for pat in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$ENV_ID" == *"$pat"* ]]; then
    log_error "SAFETY: refusing to simulate outage on protected container ($pat)"
    exit 1
  fi
done

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
[[ ! -f "$STATE_FILE" ]] && { log_error "No state file for $ENV_ID"; exit 1; }

CONTAINER=$(jq -r '.container' "$STATE_FILE")
NETWORK=$(jq  -r '.network'    "$STATE_FILE")

# Double-check the container isn't one of the protected ones
for pat in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$CONTAINER" == *"$pat"* ]]; then
    log_error "SAFETY: container $CONTAINER matches protected pattern ($pat)"
    exit 1
  fi
done

log_info "Simulating '$MODE' on env=$ENV_ID (container=$CONTAINER)"

case "$MODE" in
  crash)
    docker kill "$CONTAINER"
    update_state_key "$ENV_ID" "status" '"crashed"'
    log_info "Container killed. Health monitor should detect within 90s."
    ;;

  pause)
    docker pause "$CONTAINER"
    update_state_key "$ENV_ID" "status" '"paused"'
    log_info "Container paused. Use --mode recover to unpause."
    ;;

  network)
    docker network disconnect "$NETWORK" "$CONTAINER"
    update_state_key "$ENV_ID" "status" '"network-isolated"'
    log_info "Container disconnected from network $NETWORK."
    ;;

  recover)
    CURRENT_STATUS=$(jq -r '.status' "$STATE_FILE")
    case "$CURRENT_STATUS" in
      crashed|exited)
        docker start "$CONTAINER" || docker run -d \
          --name "$CONTAINER" \
          --network "$NETWORK" \
          --label "sandbox.env=$ENV_ID" \
          -p "$(jq -r '.host_port' "$STATE_FILE"):8080" \
          sandbox-demo-app
        ;;
      paused)
        docker unpause "$CONTAINER"
        ;;
      network-isolated)
        docker network connect "$NETWORK" "$CONTAINER"
        ;;
      *)
        log_warn "Nothing to recover for status=$CURRENT_STATUS"
        ;;
    esac
    update_state_key "$ENV_ID" "status" '"running"'
    update_state_key "$ENV_ID" "consecutive_failures" '0'
    log_info "Environment $ENV_ID recovered."
    ;;

  stress)
    # Optional: spike CPU with stress-ng if available
    if docker exec "$CONTAINER" which stress-ng >/dev/null 2>&1; then
      docker exec -d "$CONTAINER" stress-ng --cpu 0 --timeout 60s
      log_info "stress-ng running for 60s inside $CONTAINER"
    else
      log_warn "stress-ng not found in container — install it in the demo app image"
    fi
    ;;

  *)
    log_error "Unknown mode: $MODE"
    usage
    ;;
esac

echo "✅  Outage simulation '$MODE' applied to $ENV_ID"
