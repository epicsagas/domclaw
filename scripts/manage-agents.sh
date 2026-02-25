#!/usr/bin/env bash
# ============================================================
# manage-agents.sh — 에이전트 관리 CLI
# DomClaw Phase 3: 에이전트 매핑 및 봇 연동
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_BIN="${DOCKER_BIN:-docker}"

if ! command -v "$DOCKER_BIN" &>/dev/null; then
  [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]] && \
    DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
fi

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

AGENTS_FILE="$PROJECT_ROOT/config/agents.json"
BINDINGS_FILE="$PROJECT_ROOT/config/openclaw.json"

usage() {
  echo ""
  echo "Usage: $0 <command>"
  echo ""
  echo "Commands:"
  echo "  list        모든 에이전트 목록 출력"
  echo "  status      에이전트 실행 상태 확인"
  echo "  health      에이전트 헬스체크 실행"
  echo "  logs [id]   에이전트 로그 출력 (기본: 전체)"
  echo "  restart     OpenClaw Gateway 재시작"
  echo "  validate    설정 파일 유효성 검증"
  echo ""
}

cmd_list() {
  echo -e "\n${CYAN}📋 등록된 에이전트${NC}\n"

  if [[ ! -f "$AGENTS_FILE" ]]; then
    echo -e "${RED}에이전트 정의 파일을 찾을 수 없습니다: $AGENTS_FILE${NC}"
    return 1
  fi

  echo "┌──────────────────┬────────────────────┬────────┬───────────┐"
  echo "│ ID               │ Name               │ Mem MB │ Concurrent│"
  echo "├──────────────────┼────────────────────┼────────┼───────────┤"

  # Parse agents
  local ids names mems concs
  ids=$(grep -o '"id": *"[^"]*"' "$AGENTS_FILE" | cut -d'"' -f4)
  names=$(grep -o '"name": *"[^"]*"' "$AGENTS_FILE" | cut -d'"' -f4)
  mems=$(grep -o '"maxMemoryMB": *[0-9]*' "$AGENTS_FILE" | grep -o '[0-9]*$')
  concs=$(grep -o '"maxConcurrent": *[0-9]*' "$AGENTS_FILE" | grep -o '[0-9]*$')

  paste <(echo "$ids") <(echo "$names") <(echo "$mems") <(echo "$concs") | \
    while IFS=$'\t' read -r id name mem conc; do
      printf "│ %-16s │ %-18s │ %6s │ %9s │\n" "$id" "$name" "$mem" "$conc"
    done

  echo "└──────────────────┴────────────────────┴────────┴───────────┘"
  echo ""

  # Total resource usage
  local total_mem
  total_mem=$(grep -o '"maxMemoryMB": *[0-9]*' "$AGENTS_FILE" | grep -o '[0-9]*$' | paste -sd+ - | bc 2>/dev/null || echo "N/A")
  echo -e "  총 메모리 할당량: ${YELLOW}${total_mem}MB${NC}"
  echo ""
}

cmd_status() {
  echo -e "\n${CYAN}🔍 게이트웨이 상태${NC}\n"

  local container="domclaw-gateway"
  if $DOCKER_BIN ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -q "^${container}"; then
    local status
    status=$($DOCKER_BIN ps --format '{{.Status}}' --filter "name=${container}" 2>/dev/null)
    echo -e "  ${GREEN}● 실행 중${NC}  $container  ($status)"

    # Health check
    local health
    health=$($DOCKER_BIN inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    echo -e "  Health: $health"

    # Resource usage
    local stats
    stats=$($DOCKER_BIN stats "$container" --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || echo "N/A")
    echo -e "  Resources: CPU=$( echo "$stats" | cut -f1 ) | MEM=$( echo "$stats" | cut -f2 ) ($( echo "$stats" | cut -f3 ))"
  else
    echo -e "  ${RED}● 중지됨${NC}  $container"
    echo "  docker compose up -d 로 시작하세요."
  fi
  echo ""
}

cmd_health() {
  echo -e "\n${CYAN}🏥 헬스체크${NC}\n"

  local container="domclaw-gateway"
  local port="${OPENCLAW_PORT:-3100}"

  if $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    local result
    result=$($DOCKER_BIN exec "$container" wget -qO- "http://localhost:${port}/health" 2>/dev/null || echo '{"status":"unreachable"}')
    echo "  Response: $result"

    if echo "$result" | grep -qi '"ok"\|"healthy"\|"up"'; then
      echo -e "  ${GREEN}✅ 정상${NC}"
    else
      echo -e "  ${YELLOW}⚠️  비정상 응답${NC}"
    fi
  else
    echo -e "  ${RED}❌ 게이트웨이가 실행 중이 아닙니다${NC}"
  fi
  echo ""
}

cmd_logs() {
  local filter="${1:-}"

  if [[ -n "$filter" ]]; then
    echo -e "\n${CYAN}📜 에이전트 로그 (filter: $filter)${NC}\n"
    $DOCKER_BIN logs domclaw-gateway --tail 100 2>&1 | grep -i "$filter" || echo "  (매칭되는 로그 없음)"
  else
    echo -e "\n${CYAN}📜 최근 로그 (50줄)${NC}\n"
    $DOCKER_BIN logs domclaw-gateway --tail 50 2>&1
  fi
}

cmd_restart() {
  echo -e "\n${CYAN}🔄 게이트웨이 재시작 중...${NC}\n"
  $DOCKER_BIN compose -f "$PROJECT_ROOT/docker-compose.yml" restart openclaw-gateway
  echo -e "\n${GREEN}✅ 재시작 완료${NC}\n"
}

cmd_validate() {
  echo -e "\n${CYAN}✅ 설정 파일 검증${NC}\n"

  local errors=0

  # agents.json 존재 확인
  if [[ -f "$AGENTS_FILE" ]]; then
    echo -e "  ${GREEN}✓${NC} config/agents.json 존재"
    # JSON 구문 검사
    if python3 -c "import json; json.load(open('$AGENTS_FILE'))" 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} config/agents.json JSON 구문 정상"
    else
      echo -e "  ${RED}✗${NC} config/agents.json JSON 구문 오류"
      ((errors++))
    fi
  else
    echo -e "  ${RED}✗${NC} config/agents.json 파일 없음"
    ((errors++))
  fi

  # openclaw.json 존재 확인
  if [[ -f "$BINDINGS_FILE" ]]; then
    echo -e "  ${GREEN}✓${NC} config/openclaw.json 존재"
    if python3 -c "import json; json.load(open('$BINDINGS_FILE'))" 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} config/openclaw.json JSON 구문 정상"
    else
      echo -e "  ${RED}✗${NC} config/openclaw.json JSON 구문 오류"
      ((errors++))
    fi
  else
    echo -e "  ${RED}✗${NC} config/openclaw.json 파일 없음"
    ((errors++))
  fi

  # 에이전트 ID 일관성 확인
  if [[ -f "$AGENTS_FILE" && -f "$BINDINGS_FILE" ]]; then
    local binding_ids
    binding_ids=$(grep -o '"agentId": *"[^"]*"' "$BINDINGS_FILE" | cut -d'"' -f4 | sort)
    local agent_ids
    agent_ids=$(grep -o '"id": *"[^"]*"' "$AGENTS_FILE" | cut -d'"' -f4 | sort)

    while IFS= read -r bid; do
      if echo "$agent_ids" | grep -qx "$bid"; then
        echo -e "  ${GREEN}✓${NC} 바인딩 '$bid' → 에이전트 정의 확인"
      else
        echo -e "  ${RED}✗${NC} 바인딩 '$bid' → 에이전트 정의 없음!"
        ((errors++))
      fi
    done <<< "$binding_ids"
  fi

  echo ""
  if [[ $errors -eq 0 ]]; then
    echo -e "  ${GREEN}모든 검증 통과!${NC}"
  else
    echo -e "  ${RED}${errors}개 오류 발견${NC}"
  fi
  echo ""
}

# ---- Main ----
case "${1:-}" in
  list)     cmd_list ;;
  status)   cmd_status ;;
  health)   cmd_health ;;
  logs)     cmd_logs "${2:-}" ;;
  restart)  cmd_restart ;;
  validate) cmd_validate ;;
  *)        usage; exit 1 ;;
esac
