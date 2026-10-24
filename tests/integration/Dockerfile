ARG NODE_MAJOR
ARG BASE
FROM node:${NODE_MAJOR} AS node-runtime
FROM ${BASE}

COPY --from=node-runtime /usr/local/ /usr/local/

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl gawk git libstdc++6 \
    && useradd --create-home --uid 1001 --shell /bin/bash node \
    && rm -rf /var/lib/apt/lists/*

# Official npm distributions include the platform binaries.
RUN npm install --global @openai/codex@latest @anthropic-ai/claude-code@latest \
        @opencode/cli@latest @github/copilot@latest skills@latest \
    && npm cache clean --force

ENV HOME=/home/node \
    CODEX_HOME=/home/node/.codex \
    CLAUDE_CONFIG_DIR=/home/node/.claude \
    COPILOT_HOME=/home/node/.copilot \
    XDG_CONFIG_HOME=/home/node/.config \
    XDG_DATA_HOME=/home/node/.local/share \
    XDG_STATE_HOME=/home/node/.local/state \
    XDG_CACHE_HOME=/home/node/.cache \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    CI=1 \
    NO_COLOR=1

RUN mkdir -p /home/node/results && chown node:node /home/node/results
USER node
WORKDIR /repo
ENTRYPOINT ["bash", "/repo/tests/integration/check.sh"]
