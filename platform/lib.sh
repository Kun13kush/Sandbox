#!/usr/bin/env bash
# Shared helpers — sourced by all platform scripts

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CLEANUP_LOG="$ROOT_DIR/logs/cleanup.log"

# ── Logging ───────────────────────────────────────────────────────────────────
_log() {
  local level="$1"; shift
  local ts; ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "[$ts] [$level] $*"
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@" >&2; }
log_error() { _log ERROR "$@" >&2; }

_log_cleanup() {
  mkdir -p "$(dirname "$CLEANUP_LOG")"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$CLEANUP_LOG"
}

# ── Port helpers ──────────────────────────────────────────────────────────────
get_free_port() {
  local port
  for port in $(shuf -i 10000-19999 -n 100); do
    # not in use by the OS
    if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
      continue
    fi
    # not claimed by another env state file
    if grep -rl "\"host_port\": *${port}" "$ROOT_DIR/envs/" 2>/dev/null | grep -q .; then
      continue
    fi
    echo "$port"
    return
  done
  echo 1>&2 "No free port found"; exit 1
}

# ── Nginx reload ──────────────────────────────────────────────────────────────
reload_nginx() {
  local nginx_cid
  nginx_cid=$(docker ps -qf "name=sandbox-nginx" 2>/dev/null | head -1)
  if [[ -n "$nginx_cid" ]]; then
    docker exec "$nginx_cid" nginx -s reload 2>/dev/null || true
  fi
}

# ── State helpers ─────────────────────────────────────────────────────────────
list_envs() {
  for f in "$ROOT_DIR/envs/"*.json; do
    [[ -f "$f" ]] || continue
    jq -r '.id' "$f"
  done
}

get_state() {
  local env_id="$1" key="$2"
  jq -r ".$key" "$ROOT_DIR/envs/$env_id.json"
}

update_state_key() {
  local env_id="$1" key="$2" value="$3"
  local state_file="$ROOT_DIR/envs/$env_id.json"
  local tmp; tmp=$(mktemp)
  jq ".$key = $value" "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}
