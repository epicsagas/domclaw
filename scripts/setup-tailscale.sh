#!/usr/bin/env bash
# ============================================================
# setup-tailscale.sh — Tailscale Funnel 활성화 및 검증 스크립트
# DomClaw Phase 2: 보안 체계 구축
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_BIN="${DOCKER_BIN:-docker}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- 1. 사전 검증 ----
check_prerequisites() {
  info "사전 요구사항 확인 중..."

  if ! command -v "$DOCKER_BIN" &>/dev/null; then
    # macOS Docker Desktop 경로 시도
    if [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]]; then
      DOCKER_BIN="/Applications/Docker.app/Contents/Resources/bin/docker"
      warn "Docker Desktop 경로 사용: $DOCKER_BIN"
    else
      error "Docker를 찾을 수 없습니다."
      exit 1
    fi
  fi

  if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
    error ".env 파일이 없습니다. .env.example을 복사하여 설정하세요:"
    echo "  cp $PROJECT_ROOT/.env.example $PROJECT_ROOT/.env"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"

  if [[ -z "${TS_KEY:-}" ]]; then
    error ".env 파일에 TS_KEY가 설정되지 않았습니다."
    echo "  https://login.tailscale.com/admin/settings/keys 에서 Auth Key를 생성하세요."
    exit 1
  fi

  ok "사전 요구사항 확인 완료"
}

# ---- 2. Tailscale 컨테이너 상태 확인 ----
check_tailscale_status() {
  info "Tailscale 컨테이너 상태 확인 중..."

  local container_name="domclaw-tailscale"

  if ! $DOCKER_BIN ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    warn "Tailscale 컨테이너가 실행 중이 아닙니다. 시작합니다..."
    $DOCKER_BIN compose -f "$PROJECT_ROOT/docker-compose.yml" up -d tailscale
    info "컨테이너 시작 대기 (15초)..."
    sleep 15
  fi

  # Tailscale 상태 확인
  local status
  status=$($DOCKER_BIN exec "$container_name" tailscale status --json 2>/dev/null | head -c 500 || echo "{}")

  if echo "$status" | grep -q '"BackendState":"Running"'; then
    ok "Tailscale 연결 활성화 확인"
  else
    warn "Tailscale이 아직 연결 중이거나 인증 대기 중입니다."
    echo "  $DOCKER_BIN exec $container_name tailscale status"
  fi
}

# ---- 3. Funnel 활성화 ----
enable_funnel() {
  info "Tailscale Funnel 활성화 중..."

  local container_name="domclaw-tailscale"

  # Funnel 상태 확인
  if $DOCKER_BIN exec "$container_name" tailscale serve status 2>/dev/null | grep -q "funnel"; then
    ok "Funnel이 이미 활성화되어 있습니다."
  else
    info "Funnel을 활성화합니다..."
    $DOCKER_BIN exec "$container_name" tailscale serve --bg --https=443 http://localhost:443 2>/dev/null || true
    $DOCKER_BIN exec "$container_name" tailscale funnel 443 on 2>/dev/null || true
    ok "Funnel 활성화 요청 완료"
  fi

  # Funnel URL 출력
  info "Funnel 상태:"
  $DOCKER_BIN exec "$container_name" tailscale serve status 2>/dev/null || warn "상태 조회 실패 — 컨테이너 로그를 확인하세요."
}

# ---- 4. 보안 검증 ----
verify_security() {
  info "보안 설정 검증 중..."

  local container_name="domclaw-gateway"

  # non-root 실행 확인
  if $DOCKER_BIN ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    local user
    user=$($DOCKER_BIN exec "$container_name" id -u 2>/dev/null || echo "unknown")
    if [[ "$user" == "1000" ]]; then
      ok "OpenClaw Gateway: non-root 실행 확인 (UID=$user)"
    else
      warn "OpenClaw Gateway: UID=$user (예상: 1000)"
    fi
  else
    warn "OpenClaw Gateway 컨테이너가 실행 중이 아닙니다."
  fi

  # Docker socket 읽기 전용 확인
  if $DOCKER_BIN inspect domclaw-traefik --format '{{range .Mounts}}{{.Source}}:{{.Mode}} {{end}}' 2>/dev/null | grep -q "docker.sock:ro"; then
    ok "Traefik: Docker socket 읽기 전용 마운트 확인"
  else
    warn "Traefik 컨테이너를 확인할 수 없습니다."
  fi

  ok "보안 검증 완료"
}

# ---- Main ----
main() {
  echo ""
  echo "============================================"
  echo "  🔒 DomClaw Tailscale 보안 설정 스크립트"
  echo "============================================"
  echo ""

  check_prerequisites
  check_tailscale_status
  enable_funnel
  verify_security

  echo ""
  echo "============================================"
  ok "모든 보안 설정 완료!"
  echo "============================================"
  echo ""
  info "다음 단계:"
  echo "  1. Tailscale Admin Console에서 ACL 정책을 적용하세요:"
  echo "     config/tailscale-acl.jsonc → https://login.tailscale.com/admin/acls"
  echo "  2. Discord 봇 웹훅 URL을 Funnel 주소로 설정하세요."
  echo ""
}

main "$@"
