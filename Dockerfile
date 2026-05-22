# ---- Stage 1: Builder ----
FROM node:22-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential python3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY . .

RUN npm ci && npm ci --prefix web-ui && npm run build

# ---- Stage 2: Runtime ----
FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx apache2-utils gosu git curl ca-certificates jq && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@2.1.140

RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64) OPENCODE_ARCH="x64" ;; \
        aarch64) OPENCODE_ARCH="arm64" ;; \
        *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    OPENCODE_VERSION=$(curl -sL "https://api.github.com/repos/sst/opencode/releases/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"//;s/".*//') && \
    echo "Downloading opencode ${OPENCODE_VERSION} for ${OPENCODE_ARCH}" && \
    curl -sL "https://github.com/sst/opencode/releases/download/${OPENCODE_VERSION}/opencode-linux-${OPENCODE_ARCH}.tar.gz" | tar xz -C /tmp && \
    mv /tmp/opencode /usr/local/bin/opencode && \
    chmod +x /usr/local/bin/opencode && \
    opencode --version

RUN groupadd -r kanban && useradd -r -g kanban -m -s /bin/bash -d /home/kanban kanban && \
    mkdir -p /home/kanban/.cline && chown -R kanban:kanban /home/kanban && \
    mkdir -p /home/kanban/.claude && chown -R kanban:kanban /home/kanban/.claude && \
    mkdir -p /workspace && chown kanban:kanban /workspace && \
    mkdir -p /projects && chown kanban:kanban /projects && \
    mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi && \
    chown -R kanban:kanban /tmp/nginx && \
    mkdir -p /var/log/nginx && chown -R kanban:kanban /var/log/nginx && \
    touch /var/run/nginx.pid && chown kanban:kanban /var/run/nginx.pid

COPY docker/nginx.conf.template /etc/nginx/nginx.conf.template
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

COPY --from=builder /build/dist ./dist
COPY --from=builder /build/node_modules/node-pty ./node_modules/node-pty

EXPOSE 3484

VOLUME ["/home/kanban/.cline", "/workspace"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["gosu", "kanban", "node", "/app/dist/cli.js", "--host", "127.0.0.1", "--port", "3485"]
