# ============================================================
# SyntheNode — Universal Autonomous Agent Orchestration
# DomClaw Integration Docker Image
# Builds from SyntheNode GitHub repository
# ============================================================

FROM python:3.11-slim

# Labels
LABEL org.opencontainers.image.title="SyntheNode"
LABEL org.opencontainers.image.description="Universal Autonomous Agent Orchestration System"
LABEL org.opencontainers.image.source="https://github.com/epicsagas/synthenode"

# Environment
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    SYNTHENODE_PORT=8765

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Clone SyntheNode from GitHub
RUN git clone https://github.com/epicsagas/synthenode.git /app/synthenode

# Set working directory
WORKDIR /app/synthenode

# Install Python dependencies
RUN pip install -e ".[dev]"

# Create directories for persistence
RUN mkdir -p /home/synthenode/.synthenode /app/.chromadb /app/workspace && \
    useradd -m -u 1000 -s /bin/bash synthenode && \
    chown -R synthenode:synthenode /app /home/synthenode

# Switch to non-root user
USER synthenode

# Expose dashboard port
EXPOSE 8765

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8765/api/status || exit 1

# Default command (dashboard server)
CMD ["python", "-c", "from synthenode.web import run_dashboard; from synthenode.loader import load_config; from pathlib import Path; config = load_config(Path('/app/synthenode/synthenode.yaml')) if Path('/app/synthenode/synthenode.yaml').exists() else None; run_dashboard(config, Path('/app/synthenode'), port=8765) if config else __import__('uvicorn').run('synthenode.web:app', host='0.0.0.0', port=8765)"]
