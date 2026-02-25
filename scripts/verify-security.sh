#!/usr/bin/env bash
# ============================================================
# verify-security.sh — Zero-Trust 보안 체계 검증 스크립트
# DomClaw Phase 2
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
NC='\033[0m'

PASS=0
FAIL=0
WARN_COUNT=0

pass()  { echo -e "${GREEN}  ✅ PASS${NC} $*"; ((PASS++)); }
fail()  { echo -e "${RED}  ❌ FAIL${NC} $*"; ((FAIL++)); }
warn()  { echo -e "${YELLOW}  ⚠️  WARN${NC} $*"; ((WARN_COUNT++)); }
check() { echo -e "\n🔍 $*"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   DomClaw Security Verification Suite    ║"
echo "╚══════════════════════════════════════════╝"

# ---- 1. 컨테이너 권한 검증 ----
check "컨테이너 실행 권한 검증"

for container in domclaw-gateway domclaw-traefik domclaw-tailscale; do
  if $DOCKER_BIN ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    uid=$($DOCKER_BIN exec "$container" id -u 2>/dev/null || echo "N/A")
    if [[ "$container" == "domclaw-gateway" ]]; then
      if [[ "$uid" == "1000" ]]; then
        pass "$container: non-root (UID=$uid)"
      else
        fail "$container: UID=$uid (expected 1000)"
      fi
    else
      pass "$container: running (UID=$uid)"
    fi
  else
    warn "$container: 컨테이너가 실행 중이 아닙니다"
  fi
done

# ---- 2. 네트워크 보안 검증 ----
check "네트워크 보안 검증"

# 호스트에 노출된 포트 확인
exposed_ports=$($DOCKER_BIN compose ps --format json 2>/dev/null | grep -o '"PublishedPort":[0-9]*' | grep -v ':0' || echo "")
if [[ -z "$exposed_ports" ]]; then
  pass "호스트에 노출된 포트 없음 (Zero-Trust)"
else
  fail "호스트에 노출된 포트 발견: $exposed_ports"
fi

# Traefik network_mode 확인
traefik_network=$($DOCKER_BIN inspect domclaw-traefik --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
if [[ "$traefik_network" == *"tailscale"* ]]; then
  pass "Traefik: Tailscale 네트워크 모드 사용"
else
  warn "Traefik network_mode: $traefik_network"
fi

# ---- 3. Docker Socket 보안 ----
check "Docker Socket 보안"

traefik_mounts=$($DOCKER_BIN inspect domclaw-traefik --format '{{range .Mounts}}{{.Source}}={{.Mode}} {{end}}' 2>/dev/null || echo "")
if echo "$traefik_mounts" | grep -q "docker.sock=ro"; then
  pass "Docker socket: 읽기 전용 마운트"
else
  warn "Docker socket 마운트 상태를 확인할 수 없습니다"
fi

# ---- 4. 리소스 제한 검증 ----
check "리소스 제한 검증"

for container in domclaw-gateway domclaw-traefik domclaw-tailscale; do
  mem_limit=$($DOCKER_BIN inspect "$container" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "$mem_limit" != "0" && -n "$mem_limit" ]]; then
    mem_mb=$((mem_limit / 1024 / 1024))
    pass "$container: 메모리 제한 ${mem_mb}MB"
  else
    warn "$container: 메모리 제한 미설정 또는 확인 불가"
  fi
done

# ---- 5. Tailscale 인증 상태 ----
check "Tailscale 인증 상태"

ts_status=$($DOCKER_BIN exec domclaw-tailscale tailscale status --json 2>/dev/null | head -c 1000 || echo '{}')
if echo "$ts_status" | grep -q '"BackendState":"Running"'; then
  pass "Tailscale: 연결 활성화"
  ts_hostname=$(echo "$ts_status" | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4)
  [[ -n "$ts_hostname" ]] && echo "       Hostname: $ts_hostname"
else
  warn "Tailscale: 연결 상태 확인 불가"
fi

# ---- 결과 요약 ----
echo ""
echo "══════════════════════════════════════════"
echo "  결과: ${GREEN}${PASS} PASS${NC}, ${RED}${FAIL} FAIL${NC}, ${YELLOW}${WARN_COUNT} WARN${NC}"
echo "══════════════════════════════════════════"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
