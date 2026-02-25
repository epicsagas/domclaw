#!/usr/bin/env bash
# ============================================================
# setup-discord-bot.sh — Discord 봇 등록 및 웹훅 설정 스크립트
# DomClaw Phase 3: 에이전트 매핑 및 봇 연동
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- Load environment ----
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
TAILNET_DOMAIN="${TAILNET_DOMAIN:-}"
TS_HOSTNAME="${TS_HOSTNAME:-ai-commander}"

# ---- 1. 사전 검증 ----
preflight() {
  info "사전 요구사항 확인 중..."

  if [[ -z "$DISCORD_BOT_TOKEN" ]]; then
    error "DISCORD_BOT_TOKEN이 설정되지 않았습니다."
    echo ""
    echo "  1. https://discord.com/developers/applications 에서 봇 생성"
    echo "  2. Bot → Token → Copy"
    echo "  3. .env 파일에 DISCORD_BOT_TOKEN=<토큰> 추가"
    exit 1
  fi

  if [[ -z "$TAILNET_DOMAIN" ]]; then
    error "TAILNET_DOMAIN이 설정되지 않았습니다."
    echo "  예: your-name.ts.net"
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    error "curl이 설치되어 있지 않습니다."
    exit 1
  fi

  ok "사전 요구사항 확인 완료"
}

# ---- 2. Discord 봇 정보 조회 ----
verify_bot() {
  info "Discord 봇 연결 확인 중..."

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    "https://discord.com/api/v10/users/@me")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | head -n -1)

  if [[ "$http_code" == "200" ]]; then
    local bot_name
    bot_name=$(echo "$body" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
    local bot_id
    bot_id=$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    ok "봇 연결 성공: @${bot_name} (ID: ${bot_id})"
  elif [[ "$http_code" == "401" ]]; then
    error "봇 토큰이 유효하지 않습니다. 토큰을 다시 확인하세요."
    exit 1
  else
    error "Discord API 응답 오류: HTTP $http_code"
    echo "$body"
    exit 1
  fi
}

# ---- 3. Webhook URL 안내 ----
print_webhook_info() {
  local funnel_url="https://${TS_HOSTNAME}.${TAILNET_DOMAIN}"

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           Discord 봇 웹훅 설정 안내                       ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  info "Interactions Endpoint URL을 다음으로 설정하세요:"
  echo ""
  echo -e "  ${GREEN}${funnel_url}/api/discord/interactions${NC}"
  echo ""
  info "설정 위치:"
  echo "  Discord Developer Portal → Application → General Information"
  echo "  → INTERACTIONS ENDPOINT URL"
  echo ""
  info "Gateway 이벤트 수신 URL:"
  echo -e "  ${GREEN}${funnel_url}/api/discord/webhook${NC}"
  echo ""
}

# ---- 4. 채널 바인딩 상태 출력 ----
print_bindings() {
  info "에이전트 바인딩 현황:"
  echo ""

  local config_file="$PROJECT_ROOT/config/openclaw.json"
  if [[ -f "$config_file" ]]; then
    echo "  ┌─────────────────────┬──────────────────────┬─────────────────┐"
    echo "  │ Agent ID            │ Channel              │ Options         │"
    echo "  ├─────────────────────┼──────────────────────┼─────────────────┤"

    # Parse bindings from JSON (simplified grep-based parsing)
    local agent_ids
    agent_ids=$(grep -o '"agentId": *"[^"]*"' "$config_file" | cut -d'"' -f4)
    local channel_ids
    channel_ids=$(grep -o '"channelId": *"[^"]*"' "$config_file" | cut -d'"' -f4)
    local comments
    comments=$(grep -o '"comment": *"[^"]*"' "$config_file" | cut -d'"' -f4)

    paste <(echo "$agent_ids") <(echo "$channel_ids") <(echo "$comments") | while IFS=$'\t' read -r aid cid comment; do
      printf "  │ %-19s │ %-20s │ %-15s │\n" "$aid" "$cid" "${comment:0:15}"
    done

    echo "  └─────────────────────┴──────────────────────┴─────────────────┘"
  else
    warn "config/openclaw.json을 찾을 수 없습니다."
  fi
  echo ""
}

# ---- 5. 에이전트 정의 검증 ----
verify_agents() {
  info "에이전트 정의 파일 검증 중..."

  local agents_file="$PROJECT_ROOT/config/agents.json"
  if [[ -f "$agents_file" ]]; then
    local agent_count
    agent_count=$(grep -c '"id":' "$agents_file")
    ok "에이전트 정의: ${agent_count}개 에이전트 발견"

    grep -o '"id": *"[^"]*"' "$agents_file" | while read -r line; do
      local aid
      aid=$(echo "$line" | cut -d'"' -f4)
      echo "    → $aid"
    done
  else
    warn "config/agents.json을 찾을 수 없습니다."
  fi
}

# ---- Main ----
main() {
  echo ""
  echo "============================================"
  echo "  🤖 DomClaw Discord 봇 설정 스크립트"
  echo "============================================"
  echo ""

  preflight
  verify_bot
  verify_agents
  print_bindings
  print_webhook_info

  echo "============================================"
  ok "Discord 봇 설정 스크립트 완료!"
  echo "============================================"
  echo ""
  info "다음 단계:"
  echo "  1. 위 Interactions Endpoint URL을 Discord Developer Portal에 등록"
  echo "  2. config/openclaw.json의 channelId를 실제 채널 ID로 변경"
  echo "  3. docker compose up -d 로 전체 스택 재시작"
  echo ""
}

main "$@"
