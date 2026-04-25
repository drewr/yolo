FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    openssh-client \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN mkdir -p /root/.claude
COPY settings.json /root/.claude/settings.json
COPY claude-state.json /root/.claude.json

# Stamp the installed claude version into the state file
RUN CLAUDE_VERSION=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) && \
    sed -i "s/CLAUDE_VERSION/$CLAUDE_VERSION/" /root/.claude.json

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
