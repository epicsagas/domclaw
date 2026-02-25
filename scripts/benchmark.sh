#!/usr/bin/env bash
# ============================================================
# benchmark.sh — M2 MacBook 성능 벤치마크 스크립트
# DomClaw Phase 4: M2 하드웨어 최적화
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_BIN="${DOCKER_BIN:-docker}"

if ! command -v "$DOCKER_BIN" &>/dev/null; then
  [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]] && \
    DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
fi

REPORT_DIR="$PROJECT_ROOT/reports"
REPORT_FILE="$REPORT_DIR/benchmark-$(date +%Y%m%d-%H%M%S).md"
mkdir -p "$REPORT_DIR"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

# ---- Report helpers ----
report() { echo "$*" >> "$REPORT_FILE"; }
report_header() {
  report "# DomClaw Performance Benchmark Report"
  report ""
  report "- **Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  report "- **Host:** $(hostname)"
  report "- **CPU:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Unknown')"
  report "- **RAM:** $(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024))GB"
  report "- **macOS:** $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
  report ""
  report "---"
  report ""
}

# ---- 1. 컨테이너 스타트업 시간 ----
bench_startup() {
  info "📊 1/4 — 컨테이너 스타트업 시간 측정..."
  report "## 1. Container Startup Time"
  report ""

  local compose_file="$PROJECT_ROOT/docker-compose.yml"

  # Stop all containers first
  $DOCKER_BIN compose -f "$compose_file" down --remove-orphans 2>/dev/null || true
  sleep 2

  # Measure cold start
  local start_time
  start_time=$(date +%s%N)

  $DOCKER_BIN compose -f "$compose_file" up -d 2>/dev/null

  # Wait for healthcheck
  local timeout=60
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if $DOCKER_BIN inspect domclaw-gateway --format '{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
      break
    fi
    sleep 1
    ((elapsed++))
  done

  local end_time
  end_time=$(date +%s%N)
  local duration_ms=$(( (end_time - start_time) / 1000000 ))
  local duration_s=$(echo "scale=1; $duration_ms / 1000" | bc 2>/dev/null || echo "$((duration_ms / 1000))")

  report "| Metric | Value |"
  report "|---|---|"
  report "| Cold Start Time | ${duration_s}s |"
  report "| Health Status | $([ $elapsed -lt $timeout ] && echo 'Healthy' || echo 'Timeout') |"
  report ""

  if [[ $elapsed -lt $timeout ]]; then
    ok "스타트업 시간: ${duration_s}s"
  else
    echo -e "${YELLOW}[WARN]${NC} 헬스체크 타임아웃 (${timeout}s)"
  fi
}

# ---- 2. 메모리 사용량 스냅샷 ----
bench_memory() {
  info "📊 2/4 — 메모리 사용량 스냅샷..."
  report "## 2. Memory Usage Snapshot"
  report ""
  report "| Container | Memory Usage | Memory Limit | Memory % | CPU % |"
  report "|---|---|---|---|---|"

  $DOCKER_BIN stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' \
    --filter "name=domclaw" 2>/dev/null | while IFS=$'\t' read -r name mem_usage mem_pct cpu_pct; do
    local mem_limit
    mem_limit=$($DOCKER_BIN inspect "$name" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
    local limit_str="unlimited"
    [[ "$mem_limit" != "0" && -n "$mem_limit" ]] && limit_str="$((mem_limit / 1024 / 1024))MB"
    report "| $name | $mem_usage | $limit_str | $mem_pct | $cpu_pct |"
    echo "  $name: MEM=$mem_usage ($mem_pct) CPU=$cpu_pct LIMIT=$limit_str"
  done

  report ""
  ok "메모리 스냅샷 완료"
}

# ---- 3. 네트워크 레이턴시 (내부) ----
bench_latency() {
  info "📊 3/4 — 내부 네트워크 레이턴시..."
  report "## 3. Internal Network Latency"
  report ""

  local container="domclaw-gateway"
  local port="${OPENCLAW_PORT:-3100}"
  local iterations=10
  local total=0
  local min=999999
  local max=0

  if $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    for i in $(seq 1 $iterations); do
      local start_ns
      start_ns=$(date +%s%N)
      $DOCKER_BIN exec "$container" wget -qO- "http://localhost:${port}/health" >/dev/null 2>&1 || true
      local end_ns
      end_ns=$(date +%s%N)
      local latency_ms=$(( (end_ns - start_ns) / 1000000 ))
      total=$((total + latency_ms))
      [[ $latency_ms -lt $min ]] && min=$latency_ms
      [[ $latency_ms -gt $max ]] && max=$latency_ms
    done

    local avg=$((total / iterations))

    report "| Metric | Value |"
    report "|---|---|"
    report "| Iterations | $iterations |"
    report "| Average | ${avg}ms |"
    report "| Min | ${min}ms |"
    report "| Max | ${max}ms |"
    report ""

    ok "평균 레이턴시: ${avg}ms (min=${min}ms, max=${max}ms)"
  else
    report "Gateway container not running — skipped."
    report ""
    echo -e "${YELLOW}[WARN]${NC} 게이트웨이가 실행 중이 아닙니다 — 건너뜀"
  fi
}

# ---- 4. OOM 방어 테스트 ----
bench_oom_defense() {
  info "📊 4/4 — OOM 방어 검증..."
  report "## 4. OOM Defense Verification"
  report ""

  local containers
  containers=$($DOCKER_BIN ps --format '{{.Names}}' --filter "name=domclaw" 2>/dev/null || echo "")

  report "| Container | Memory Limit | OOM Kill Disabled | Restart Policy |"
  report "|---|---|---|---|"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local mem_limit
    mem_limit=$($DOCKER_BIN inspect "$name" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
    local oom_disabled
    oom_disabled=$($DOCKER_BIN inspect "$name" --format '{{.HostConfig.OomKillDisable}}' 2>/dev/null || echo "false")
    local restart
    restart=$($DOCKER_BIN inspect "$name" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "no")

    local limit_str="unlimited"
    [[ "$mem_limit" != "0" && -n "$mem_limit" ]] && limit_str="$((mem_limit / 1024 / 1024))MB"

    report "| $name | $limit_str | $oom_disabled | $restart |"
    echo "  $name: limit=$limit_str oom_kill_disabled=$oom_disabled restart=$restart"
  done <<< "$containers"

  report ""
  ok "OOM 방어 검증 완료"
}

# ---- Summary ----
print_summary() {
  report "---"
  report ""
  report "## Summary"
  report ""
  report "Benchmark completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
  report ""
  report "> Report generated by DomClaw benchmark.sh"
}

# ---- Main ----
main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   📊 DomClaw Performance Benchmark       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  report_header
  bench_startup
  bench_memory
  bench_latency
  bench_oom_defense
  print_summary

  echo ""
  echo "═══════════════════════════════════════════"
  ok "벤치마크 완료!"
  echo "  리포트: $REPORT_FILE"
  echo "═══════════════════════════════════════════"
  echo ""
}

main "$@"
