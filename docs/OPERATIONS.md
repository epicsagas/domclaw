# DomClaw 운영 매뉴얼

## 목차

1. [일상 운영](#1-일상-운영)
2. [장애 대응](#2-장애-대응)
3. [에이전트 관리](#3-에이전트-관리)
4. [백업 및 복구](#4-백업-및-복구)
5. [참고 명령어](#5-참고-명령어)
6. [OpenCode 연동](#6-opencode-연동)

---

## 1. 일상 운영

### 스택 시작/중지

```bash
# 기본 시작
./domclaw up

# 16GB RAM 프로필로 시작
./domclaw up --16g

# 24GB+ RAM 프로필로 시작
./domclaw up --24g

# 중지
./domclaw down

# 재시작
./domclaw restart
```

### 상태 확인

```bash
# 서비스 상태
./domclaw status

# 리소스 모니터링 (실시간)
./domclaw monitor --watch

# 에이전트 목록
./domclaw agents list

# 에이전트 헬스체크
./domclaw agents health
```

### 로그 확인

```bash
# 게이트웨이 로그 (실시간)
./domclaw logs gateway

# Traefik 로그
./domclaw logs traefik

# Tailscale 로그
./domclaw logs tailscale

# 헬스체크 로그
cat logs/healthcheck.log
```

---

## 2. 장애 대응

### 증상별 대응 매뉴얼

#### 🔴 에이전트 응답 없음

```bash
# 1. 상태 확인
./domclaw status

# 2. 게이트웨이 헬스체크
./domclaw agents health

# 3. 게이트웨이 재시작
docker restart domclaw-gateway

# 4. 로그 확인
./domclaw logs gateway
```

#### 🔴 메모리 부족 (OOM)

```bash
# 1. 리소스 확인
./domclaw monitor

# 2. 16GB 프로필로 전환
./domclaw down
./domclaw up --16g

# 3. Docker 캐시 정리
docker system prune -f
docker volume prune -f
```

#### 🔴 Tailscale 연결 끊김

```bash
# 1. Tailscale 상태 확인
docker exec domclaw-tailscale tailscale status

# 2. Tailscale 재시작
docker restart domclaw-tailscale

# 3. 인증 키 만료 시 — .env 의 TS_KEY 갱신 후
./domclaw restart
```

#### 🔴 Traefik 라우팅 오류

```bash
# 1. Traefik 대시보드 확인 (Tailscale 망 내에서)
# http://ai-commander:8080/dashboard/

# 2. Traefik 설정 유효성 검증
docker exec domclaw-traefik traefik healthcheck

# 3. 라벨 확인
docker inspect domclaw-gateway --format '{{json .Config.Labels}}' | python3 -m json.tool
```

---

## 3. 에이전트 관리

### 새 에이전트 추가

1. **`config/agents.json`에 에이전트 정의 추가:**

```json
{
  "id": "new-agent-id",
  "name": "New Agent",
  "description": "설명",
  "model": "claude-sonnet-4-20250514",
  "systemPrompt": "시스템 프롬프트",
  "capabilities": ["capability1"],
  "workspace": "/workspace/projects/new-project",
  "resources": {
    "maxMemoryMB": 512,
    "maxConcurrent": 2,
    "timeoutMs": 60000
  },
  "tools": [
    { "name": "file-read", "enabled": true }
  ]
}
```

2. **`config/openclaw.json`에 바인딩 추가:**

```json
{
  "comment": "새 에이전트",
  "match": { "channel": "discord", "channelId": "CHANNEL_ID" },
  "agentId": "new-agent-id",
  "options": { "requireMention": true }
}
```

3. **설정 검증 및 반영:**

```bash
./domclaw agents validate
docker restart domclaw-gateway
```

### 에이전트 제거

1. `config/agents.json`에서 에이전트 정의 삭제
2. `config/openclaw.json`에서 해당 바인딩 삭제
3. `./domclaw agents validate && docker restart domclaw-gateway`

---

## 4. 백업 및 복구

### 설정 백업

```bash
# 설정 파일 백업
tar czf domclaw-config-$(date +%Y%m%d).tar.gz \
  config/ traefik.yml dynamic.yml docker-compose*.yml .env

# Tailscale 상태 백업 (Named Volume)
docker run --rm -v domclaw_tailscale-state:/data -v "$(pwd)":/backup \
  alpine tar czf /backup/tailscale-state-$(date +%Y%m%d).tar.gz -C /data .

# OpenClaw 데이터 백업 (호스트 바인드 마운트 기준)
tar czf openclaw-data-$(date +%Y%m%d).tar.gz -C /Volumes/Micron .openclaw

# OpenCode 데이터 백업 (호스트 바인드 마운트 기준)
tar czf opencode-data-$(date +%Y%m%d).tar.gz -C /Volumes/Micron .opencode
```

### 설정 복구

```bash
# 설정 복구
tar xzf domclaw-config-YYYYMMDD.tar.gz

# Volume 복구
docker volume create domclaw_tailscale-state
docker run --rm -v domclaw_tailscale-state:/data -v $(pwd):/backup \
  alpine tar xzf /backup/tailscale-state-YYYYMMDD.tar.gz -C /data

./domclaw up
```

---

## 6. OpenCode 연동

OpenCode는 **호스트에서 직접 실행**하며, Docker 컨테이너는 `host.docker.internal`을 통해 접근합니다.

### 구성 개요

```mermaid
flowchart TB
    subgraph Docker["Docker Stack"]
        TS["Tailscale"]
        TR["Traefik v3"]
        GW["OpenClaw Gateway<br/>:3100"]
        SN["SyntheNode<br/>:8765"]
        
        TS -.->|network_mode| TR
        TR --> GW
        TR --> SN
    end

    subgraph Host["호스트 (macOS)"]
        OC["OpenCode HTTP Server<br/>:4096"]
        CMD["$ opencode serve --hostname 0.0.0.0"]
        CMD --> OC
    end

    GW -->|host.docker.internal:4096| OC
    SN -->|host.docker.internal:4096| OC
```

### 사전 요구사항

DomClaw 스택 시작 전, 호스트에서 OpenCode 서버를 실행해야 합니다:

```bash
# OpenCode HTTP 서버 시작
opencode serve --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100

# 또는 웹 UI 포함
opencode web --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100
```

### .env 설정

```bash
# ---- OpenCode (호스트) ----
# OpenCode HTTP API port (호스트에서 실행 중인 서버)
OPENCODE_PORT=4096
```

### docker-compose 핵심 설정

```yaml
services:
  openclaw-gateway:
    environment:
      # Host OpenCode HTTP API
      - OPENCODE_BASE_URL=http://host.docker.internal:${OPENCODE_PORT:-4096}
    networks:
      - core-internal

  synthenode:
    environment:
      - OPENCODE_BASE_URL=http://host.docker.internal:${OPENCODE_PORT:-4096}
    networks:
      - core-internal

networks:
  core-internal:
    driver: bridge
```

### 재시작 절차

```bash
# 1. 호스트에서 OpenCode 시작
opencode serve --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100

# 2. DomClaw 스택 시작
./domclaw up
```

### 연결 확인

```bash
# 호스트 OpenCode 서버 확인
curl http://localhost:4096/api/status

# 컨테이너에서 호스트 접근 확인
docker exec domclaw-gateway curl http://host.docker.internal:4096/api/status
```

> 자세한 내용은 [Host OpenCode 연동 가이드](./HOST_OPENCODE_GUIDE.md)를 참조하세요.

---

## 5. 참고 명령어

### 자동 헬스체크 크론탭 등록

```bash
# 5분마다 헬스체크 + 자동 복구
(crontab -l 2>/dev/null; echo "*/5 * * * * $(pwd)/scripts/healthcheck.sh") | crontab -
```

### Docker 리소스 정리

```bash
# 미사용 이미지/캐시 정리
docker system prune -f

# 미사용 볼륨 정리 (주의: 데이터 손실 가능)
docker volume prune -f

# 전체 DomClaw 초기화
./domclaw down
docker volume rm domclaw_tailscale-state domclaw_openclaw-data
./domclaw up
```

### 보안 감사

```bash
# 보안 검증 실행
./domclaw security

# 벤치마크 보고서 생성
./domclaw benchmark
```
