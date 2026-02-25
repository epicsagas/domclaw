#!/usr/bin/env bash
# ============================================================
# healthcheck.sh — 통합 헬스체크 및 자동 복구 스크립트
# DomClaw Phase 5: 운영 안정화
# 크론탭 등록: */5 * * * * /path/to/scripts/healthcheck.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/healthcheck.log"
DOCKER_BIN="${DOCKER_BIN:-docker}"

if ! command -v "$DOCKER_BIN" &>/dev/null; then
  [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]] && \
    DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
fi

mkdir -p "$LOG_DIR"

# ---- Logging ----
log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
  [[ -t 1 ]] && echo "[$(date '+%H:%M:%S')] [$level] $*"
}

# ---- Container health check ----
check_container() {
  local name="$1"
  local container="domclaw-${name}"

  if ! $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    log "ERROR" "$container: NOT RUNNING"
    return 1
  fi

  # Check Docker health status
  local health
  health=$($DOCKER_BIN inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' 2>/dev/null || echo "unknown")

  case "$health" in
    healthy|running)
      log "OK" "$container: $health"
      return 0
      ;;
    unhealthy)
      log "WARN" "$container: UNHEALTHY — attempting restart"
      return 1
      ;;
    *)
      log "WARN" "$container: status=$health"
      return 1
      ;;
  esac
}

# ---- Auto-recovery ----
recover_container() {
  local name="$1"
  local container="domclaw-${name}"

  log "INFO" "Restarting $container..."
  $DOCKER_BIN restart "$container" 2>/dev/null

  # Wait and verify
  sleep 10

  if $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    log "OK" "$container: recovered successfully"
    return 0
  else
    log "ERROR" "$container: recovery FAILED"
    return 1
  fi
}

# ---- Memory watchdog ----
check_memory() {
  local container="$1"
  local full_name="domclaw-${container}"

  local mem_usage
  mem_usage=$($DOCKER_BIN stats "$full_name" --no-stream --format '{{.MemPerc}}' 2>/dev/null | tr -d '%' || echo "0")

  # Extract integer part
  local mem_int
  mem_int=$(echo "$mem_usage" | cut -d'.' -f1)

  if [[ ${mem_int:-0} -ge 90 ]]; then
    log "CRIT" "$full_name: memory at ${mem_usage}% — CRITICAL"
    return 2
  elif [[ ${mem_int:-0} -ge 70 ]]; then
    log "WARN" "$full_name: memory at ${mem_usage}% — elevated"
    return 1
  else
    log "OK" "$full_name: memory at ${mem_usage}%"
    return 0
  fi
}

# ---- Disk space check ----
check_disk() {
  local docker_root
  docker_root=$($DOCKER_BIN info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")

  local disk_pct
  disk_pct=$(df -h "$HOME" 2>/dev/null | tail -1 | awk '{gsub(/%/,""); print $5}')

  if [[ ${disk_pct:-0} -ge 90 ]]; then
    log "CRIT" "Disk usage: ${disk_pct}% — consider docker system prune"
    return 1
  elif [[ ${disk_pct:-0} -ge 75 ]]; then
    log "WARN" "Disk usage: ${disk_pct}%"
    return 0
  else
    log "OK" "Disk usage: ${disk_pct}%"
    return 0
  fi
}

# ---- Log rotation ----
rotate_logs() {
  local max_size=10485760  # 10MB
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat --printf="%s" "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $size -ge $max_size ]]; then
      mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d)"
      log "INFO" "Log rotated (previous: ${size} bytes)"
      # Keep only last 5 rotated logs
      ls -t "${LOG_FILE}."* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
  fi
}

# ---- Main ----
main() {
  rotate_logs
  log "INFO" "=== Health check started ==="

  local failures=0
  local containers=("tailscale" "traefik" "gateway")

  for c in "${containers[@]}"; do
    if ! check_container "$c"; then
      recover_container "$c" || ((failures++))
    fi
  done

  # Memory watchdog (only for running containers)
  for c in "${containers[@]}"; do
    check_memory "$c" || true
  done

  # Disk check
  check_disk || true

  if [[ $failures -gt 0 ]]; then
    log "ERROR" "=== Health check completed with $failures failures ==="
    exit 1
  else
    log "OK" "=== Health check completed successfully ==="
  fi
}

main "$@"
