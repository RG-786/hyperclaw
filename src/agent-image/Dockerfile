FROM python:3.12-slim

LABEL maintainer="HyperClaw" \
      description="NanoClaw isolated agent container" \
      version="1.0"

# Minimal runtime deps
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      sqlite3 curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Create unprivileged agent user
RUN useradd -m -u 1001 -s /bin/bash agent

# Install Python AI SDKs (lightweight versions)
RUN pip install --no-cache-dir \
    anthropic==0.34.0 \
    openai==1.47.0 \
    requests==2.32.3 \
    httpx==0.27.2

WORKDIR /workspace
USER agent

COPY --chown=agent:agent agent_runner.py /workspace/agent_runner.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AGENT_ID="unknown" \
    HC_DB_PATH="/data/queue.db"

ENTRYPOINT ["python", "-u", "/workspace/agent_runner.py"]
