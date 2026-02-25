#!/usr/bin/env bash
# ============================================================
# monitor-resources.sh — M2 MacBook 리소스 모니터링 대시보드
# DomClaw Phase 4: M2 하드웨어 최적화
# ============================================================
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
if ! command -v "$DOCKER_BIN" &>/dev/null; then
  [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]] && \
    DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Memory thresholds (percentage)
WARN_THRESHOLD=70
CRIT_THRESHOLD=90

# ---- 시스템 정보 ----
print_system_info() {
  echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     🖥️  DomClaw M2 Resource Monitor              ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

  # macOS 시스템 정보
  local total_mem
  total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  local total_mem_gb
  total_mem_gb=$((total_mem / 1024 / 1024 / 1024))

  local cpu_brand
  cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")

  local cpu_cores
  cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")

  echo -e "  ${CYAN}CPU:${NC}    $cpu_brand"
  echo -e "  ${CYAN}Cores:${NC}  $cpu_cores"
  echo -e "  ${CYAN}RAM:${NC}    ${total_mem_gb}GB"
  echo -e "  ${CYAN}Time:${NC}   $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
}

# ---- macOS 메모리 사용량 ----
print_host_memory() {
  echo -e "${BOLD}── Host Memory ──────────────────────────────────${NC}"

  local page_size
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)

  local vm_stat_output
  vm_stat_output=$(vm_stat 2>/dev/null || echo "")

  if [[ -n "$vm_stat_output" ]]; then
    local free
    free=$(echo "$vm_stat_output" | grep "Pages free" | grep -o '[0-9]*' | tail -1)
    local active
    active=$(echo "$vm_stat_output" | grep "Pages active" | grep -o '[0-9]*' | tail -1)
    local inactive
    inactive=$(echo "$vm_stat_output" | grep "Pages inactive" | grep -o '[0-9]*' | tail -1)
    local wired
    wired=$(echo "$vm_stat_output" | grep "Pages wired" | grep -o '[0-9]*' | tail -1)
    local compressed
    compressed=$(echo "$vm_stat_output" | grep "Pages occupied by compressor" | grep -o '[0-9]*' | tail -1)

    local total_mem
    total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    local total_mb=$((total_mem / 1024 / 1024))

    local used_pages=$(( (active + wired + compressed) ))
    local used_mb=$(( used_pages * page_size / 1024 / 1024 ))
    local free_mb=$(( total_mb - used_mb ))
    local pct=$(( used_mb * 100 / total_mb ))

    local color=$GREEN
    [[ $pct -ge $WARN_THRESHOLD ]] && color=$YELLOW
    [[ $pct -ge $CRIT_THRESHOLD ]] && color=$RED

    # Progress bar
    local bar_len=30
    local filled=$(( pct * bar_len / 100 ))
    local empty=$(( bar_len - filled ))
    local bar
    bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')

    echo -e "  Used:  ${color}${used_mb}MB${NC} / ${total_mb}MB (${color}${pct}%${NC})"
    echo -e "  [${color}${bar}${NC}]"
    echo -e "  Free:  ${free_mb}MB  |  Active: $((active * page_size / 1024 / 1024))MB  |  Wired: $((wired * page_size / 1024 / 1024))MB  |  Compressed: $((compressed * page_size / 1024 / 1024))MB"
  else
    echo "  (vm_stat 사용 불가)"
  fi
  echo ""
}

# ---- Docker 컨테이너 리소스 ----
print_container_resources() {
  echo -e "${BOLD}── Container Resources ──────────────────────────${NC}"

  local containers
  containers=$($DOCKER_BIN ps --format '{{.Names}}' --filter "name=domclaw" 2>/dev/null || echo "")

  if [[ -z "$containers" ]]; then
    echo -e "  ${YELLOW}DomClaw 컨테이너가 실행 중이 아닙니다.${NC}"
    echo ""
    return
  fi

  echo ""
  printf "  ${BOLD}%-22s %8s %15s %8s %15s${NC}\n" "CONTAINER" "CPU%" "MEM USAGE" "MEM%" "MEM LIMIT"
  echo "  ─────────────────────────────────────────────────────────────────"

  $DOCKER_BIN stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' \
    --filter "name=domclaw" 2>/dev/null | while IFS=$'\t' read -r name cpu mem_usage mem_pct; do

    # Get memory limit from inspect
    local mem_limit
    mem_limit=$($DOCKER_BIN inspect "$name" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
    local limit_str="unlimited"
    if [[ "$mem_limit" != "0" && -n "$mem_limit" ]]; then
      limit_str="$((mem_limit / 1024 / 1024))MB"
    fi

    # Color based on percentage
    local pct_num
    pct_num=$(echo "$mem_pct" | tr -d '%' | cut -d'.' -f1)
    local color=$GREEN
    [[ ${pct_num:-0} -ge $WARN_THRESHOLD ]] && color=$YELLOW
    [[ ${pct_num:-0} -ge $CRIT_THRESHOLD ]] && color=$RED

    printf "  %-22s %8s %15s ${color}%8s${NC} %15s\n" "$name" "$cpu" "$mem_usage" "$mem_pct" "$limit_str"
  done

  echo ""

  # Total DomClaw memory footprint
  local total_docker_mem
  total_docker_mem=$($DOCKER_BIN stats --no-stream --format '{{.MemUsage}}' --filter "name=domclaw" 2>/dev/null | \
    grep -o '^[0-9.]*[MG]iB' | awk '{
      if ($0 ~ /GiB/) { gsub(/GiB/,""); sum += $0 * 1024; }
      else { gsub(/MiB/,""); sum += $0; }
    } END { printf "%.0f", sum }')

  echo -e "  ${CYAN}Total DomClaw Footprint:${NC} ${total_docker_mem:-0}MB"
  echo ""
}

# ---- Docker Desktop VM 리소스 설정 ----
print_docker_desktop_info() {
  echo -e "${BOLD}── Docker Desktop Settings ─────────────────────${NC}"

  local settings_file="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
  local legacy_file="$HOME/Library/Group Containers/group.com.docker/settings.json"

  local settings=""
  if [[ -f "$settings_file" ]]; then
    settings="$settings_file"
  elif [[ -f "$legacy_file" ]]; then
    settings="$legacy_file"
  fi

  if [[ -n "$settings" ]]; then
    local vm_mem
    vm_mem=$(python3 -c "import json; d=json.load(open('$settings')); print(d.get('memoryMiB', d.get('memory', 'N/A')))" 2>/dev/null || echo "N/A")
    local vm_cpus
    vm_cpus=$(python3 -c "import json; d=json.load(open('$settings')); print(d.get('cpus', 'N/A'))" 2>/dev/null || echo "N/A")
    local vm_swap
    vm_swap=$(python3 -c "import json; d=json.load(open('$settings')); print(d.get('swapMiB', d.get('swap', 'N/A')))" 2>/dev/null || echo "N/A")

    echo -e "  VM Memory:  ${vm_mem}MB"
    echo -e "  VM CPUs:    ${vm_cpus}"
    echo -e "  VM Swap:    ${vm_swap}MB"
  else
    echo "  (Docker Desktop 설정 파일을 찾을 수 없습니다)"
  fi
  echo ""
}

# ---- 권장 사항 ----
print_recommendations() {
  echo -e "${BOLD}── Recommendations ─────────────────────────────${NC}"

  local total_mem
  total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  local total_gb=$((total_mem / 1024 / 1024 / 1024))

  if [[ $total_gb -le 16 ]]; then
    echo -e "  ${YELLOW}⚠️  16GB RAM 환경: 에이전트 동시 실행을 3개 이하로 제한하세요.${NC}"
    echo -e "  ${CYAN}💡 Docker Desktop VM 메모리를 6GB로 설정하는 것을 권장합니다.${NC}"
    echo -e "  ${CYAN}💡 gateway 메모리 제한을 2G로 낮추는 것을 고려하세요.${NC}"
  elif [[ $total_gb -le 24 ]]; then
    echo -e "  ${GREEN}✅ 24GB RAM 환경: 현재 설정(4G 제한)이 적절합니다.${NC}"
    echo -e "  ${CYAN}💡 Docker Desktop VM 메모리를 8GB로 설정하는 것을 권장합니다.${NC}"
  else
    echo -e "  ${GREEN}✅ ${total_gb}GB RAM 환경: 충분한 여유가 있습니다.${NC}"
  fi
  echo ""
}

# ---- Main ----
main() {
  print_system_info
  print_host_memory
  print_docker_desktop_info
  print_container_resources
  print_recommendations
}

# Watch 모드 지원
if [[ "${1:-}" == "--watch" || "${1:-}" == "-w" ]]; then
  interval="${2:-5}"
  echo "Watch mode: ${interval}초 간격으로 갱신 (Ctrl+C로 종료)"
  while true; do
    clear
    main
    sleep "$interval"
  done
else
  main
fi
