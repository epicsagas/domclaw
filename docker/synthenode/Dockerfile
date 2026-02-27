# ============================================================
# SyntheNode — Universal Autonomous Agent Orchestration
# DomClaw Integration Docker Image
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
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash synthenode

# Set working directory
WORKDIR /app

# Copy project files
COPY pyproject.toml ./
COPY src/ ./src/
COPY agents/ ./agents/
COPY knowledge/ ./knowledge/

# Install dependencies
RUN pip install -e ".[dev]"

# Create directories for persistence
RUN mkdir -p /home/synthenode/.synthenode /app/.chromadb && \
    chown -R synthenode:synthenode /app /home/synthenode

# Switch to non-root user
USER synthenode

# Expose dashboard port
EXPOSE 8765

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8765/api/status || exit 1

# Default command (dashboard server)
CMD ["python", "-m", "synthenode.web", "--port", "8765"]
