# SyntheNode 통합 가이드

**작성일**: 2026-02-27  
**버전**: v2026.2

---

## 개요

SyntheNode는 DomClaw 인프라에 통합된 **범용 자율 에이전트 오케스트레이션 시스템**입니다. 5개의 AI 코딩 에이전트(Claude Code, Antigravity, Cursor, Codex, OpenCode)를 조율합니다.

---

## 아키텍처

```mermaid
flowchart TB
    subgraph External["외부 접근"]
        TF["Tailscale Funnel<br/>(HTTPS :443 only)"]
    end

    TF --> TR

    subgraph Docker["Docker Stack"]
        TR["Traefik v3<br/>(Domain/Path 라우팅)"]
        
        TR --> OG["OpenClaw Gateway<br/>:3100"]
        TR --> SN["SyntheNode Dashboard<br/>:8765"]
        
        OG --> OC
        SN --> OC
        
        subgraph HostAccess["호스트 접근"]
            OC["host.docker.internal:4096"]
        end
    end

    subgraph Host["호스트 (macOS)"]
        OCS["OpenCode HTTP Server<br/>$ opencode serve --hostname 0.0.0.0<br/>--port 4096"]
    end

    OC -.->|HTTP API| OCS
```

---

## 외부 접근 URL

| 서비스 | URL | 설명 |
|---|---|---|
| **OpenClaw Bot** | `https://ai-commander.tailnet.ts.net/` | Discord 웹훅 (Discord IP만) |
| **OpenClaw Admin** | `https://ai-commander.tailnet.ts.net/admin` | 대시보드 |
| **SyntheNode** | `https://ai-commander.tailnet.ts.net/synthenode` | 오케스트레이션 대시보드 |
| **Traefik Dashboard** | `http://127.0.0.1:8080` | 내부 전용 (Tailscale 망) |

---

## 서비스 구성

### 1. SyntheNode 컨테이너

```yaml
synthenode:
  image: phioranex/synthenode:latest
  container_name: domclaw-synthenode
  environment:
    - SYNTHENODE_PORT=8765
    - OPENCLAW_BASE_URL=http://openclaw-gateway:3100
    - OPENCODE_BASE_URL=http://host.docker.internal:4096  # 호스트 OpenCode
    - CHROMADB_PERSIST_DIR=/app/chromadb
    - OPENAI_API_KEY=${OPENAI_API_KEY}
    - EMBEDDING_PROVIDER=openai
  volumes:
    - chromadb-persistence:/app/chromadb
    - ./config/synthenode.yaml:/app/synthenode.yaml:ro
  networks:
    - core-internal
```

### 2. 리소스 제한

| 서비스 | 메모리 | CPU |
|---|---|---|
| SyntheNode | 2GB | 2.0 |
| OpenClaw | 4GB | 4.0 |
| Traefik | 256MB | - |
| Tailscale | 256MB | - |
| **OpenCode (호스트)** | - | - |

---

## 사전 요구사항

### 호스트에서 OpenCode 실행

DomClaw 스택을 시작하기 전에 호스트에서 OpenCode HTTP 서버를 실행해야 합니다:

```bash
# 방법 1: 헤드리스 서버
opencode serve --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100

# 방법 2: 웹 UI 포함
opencode web --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100

# 방법 3: 인증 추가
OPENCODE_SERVER_PASSWORD=your-password opencode serve \
  --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100
```

자세한 내용은 [Host OpenCode 연동 가이드](./HOST_OPENCODE_GUIDE.md)를 참조하세요.

---

## 설정 파일

### config/synthenode.yaml

```yaml
version: "1.0"

project:
  name: "domclaw"
  description: "DomClaw AI Agent Infrastructure"

units:
  domclaw-backend:
    tool: opencode
    model: glm-5
    role: backend
    skills: [git-atomic, security-scan]

knowledge:
  path: "./knowledge"
  embedding_model: "text-embedding-3-small"
  vector_db: "chromadb"

integration:
  openclaw:
    base_url: "http://openclaw-gateway:3100"
    enabled: true
  opencode:
    base_url: "http://host.docker.internal:4096"  # 호스트 OpenCode
    enabled: true
```

---

## 환경 변수

### .env 필수 항목

```bash
# SyntheNode
SYNTHENODE_PORT=8765
SYNTHENODE_IMAGE=phioranex/synthenode:latest
SYNTHENODE_MEMORY_LIMIT=2G
EMBEDDING_PROVIDER=openai
OPENAI_API_KEY=sk-xxxxxxxxxxxxx

# OpenCode (호스트)
OPENCODE_PORT=4096

# Tailscale
TS_KEY=tskey-auth-xxxxxxxxxxxxx
TAILNET_DOMAIN=your-tailnet.ts.net

# OpenClaw
DISCORD_BOT_TOKEN=your-discord-bot-token
```

---

## 실행

```bash
# 1. 호스트에서 OpenCode 시작
opencode serve --hostname 0.0.0.0 --port 4096 --cors http://localhost:3100

# 2. DomClaw 스택 시작
./domclaw up

# 3. SyntheNode 로그 확인
./domclaw logs synthenode

# 4. 상태 확인
./domclaw status
```

---

## 대시보드 접근

### SyntheNode Dashboard

```
https://ai-commander.tailnet.ts.net/synthenode
```

실시간 에이전트 상태 모니터링:
- Unit 상태 (running/stopped/failed)
- 모델 정보
- PID 및 시작 시간
- 재시도 횟수

### API 엔드포인트

```
GET /api/status   # 모든 유닛 상태 반환
```

---

## ChromaDB 지속성

벡터 데이터베이스는 Docker named volume에 저장:

```bash
# 볼륨 확인
docker volume ls | grep chromadb

# 백업
docker run --rm -v chromadb-persistence:/data -v "$(pwd)":/backup alpine tar czf /backup/chromadb-backup.tar.gz /data
```

---

## 문제 해결

### SyntheNode 시작 실패

```bash
# 로그 확인
./domclaw logs synthenode

# 일반적인 원인:
# 1. OPENAI_API_KEY 누락
# 2. ChromaDB 볼륨 권한 문제
# 3. OpenClaw 연결 실패
# 4. 호스트 OpenCode 서버 미실행
```

### OpenCode 연결 실패

```bash
# 호스트 OpenCode 서버 확인
curl http://localhost:4096/api/status

# 컨테이너에서 호스트 접근 확인
docker exec domclaw-gateway curl http://host.docker.internal:4096/api/status
```

### 대시보드 접근 불가

```bash
# Traefik 라우팅 확인
curl -H "Host: ai-commander.tailnet.ts.net" http://localhost:443/synthenode/api/status

# Tailscale Funnel 상태 확인
docker exec domclaw-tailscale tailscale status
```

---

## 참고 자료

- [SyntheNode GitHub](https://github.com/epicsagas/synthenode)
- [OpenClaw 문서](https://docs.openclaw.ai)
- [Traefik v3 문서](https://doc.traefik.io/traefik/)
- [Host OpenCode 연동 가이드](./HOST_OPENCODE_GUIDE.md)
