## 1. Create Docker support files

- [x] 1.1 Create `docker/entrypoint.sh` — base entrypoint: nginx setup, basic auth, project registration, claude auth config, default agent config, permission fix, nginx+kanban startup with signal handling
- [x] 1.2 Create `docker/entrypoint-zai.sh` — ZAI extension entrypoint: sources base entrypoint, then runs `configure_zai_mcp()` which checks for `Z_AI_API_KEY` and writes 4 MCP server entries (zai-mcp-server, web-search-prime, web-reader, zread) into `.claude.json`
- [x] 1.3 Create `docker/nginx.conf.template` — port the existing nginx template with basic auth placeholder (`#AUTH_DIRECTIVE#`), WebSocket proxy, CORS headers, and `proxy_read_timeout 86400s`
- [x] 1.4 Create `.dockerignore` — exclude `.git`, `node_modules`, `openspec`, docs from build context

## 2. Create base Dockerfile

- [x] 2.1 Stage 1 (builder): FROM `node:22-slim`, install build-essential + python3 (for node-pty), `npm ci`, `npm run build` (includes web-ui build)
- [x] 2.2 Stage 2 (runtime): FROM `node:22-slim`, install nginx, gosu, git, curl, ca-certificates, jq, apache2-utils
- [x] 2.3 Install claude-code CLI and opencode CLI
- [x] 2.4 Create kanban user, set up directories (`/home/kanban/.cline`, `/home/kanban/.claude`, `/workspace`, `/projects`, nginx temp dirs)
- [x] 2.5 COPY nginx.conf.template and entrypoint.sh from `docker/`
- [x] 2.6 COPY `dist/` and `package.json`/`package-lock.json` from builder, run `npm ci --omit=dev`, copy `node_modules/node-pty` native binding from builder
- [x] 2.7 Set ENTRYPOINT to `/entrypoint.sh`, CMD to `["gosu", "kanban", "node", "/app/dist/cli.js", "--host", "127.0.0.1", "--port", "3485"]`
- [x] 2.8 EXPOSE 3484, VOLUME `/home/kanban/.cline` and `/workspace`

## 3. Create ZAI extension Dockerfile

- [x] 3.1 Create `Dockerfile.zai` — FROM `ghcr.io/resultcrafter/cline-kanban:latest` (the base image)
- [x] 3.2 Install `@z_ai/mcp-server` npm package globally
- [x] 3.3 COPY `docker/entrypoint-zai.sh` as the entrypoint (replaces base entrypoint, calls it first then adds ZAI MCP setup)

## 4. Create GHCR GitHub Actions workflow

- [x] 4.1 Create `.github/workflows/container.yml` with trigger on push to `main`, tag `v*`, and `workflow_dispatch`
- [x] 4.2 Add `permissions: contents: read, packages: write` for GHCR push
- [x] 4.3 Build base image step: `docker build -f Dockerfile -t ghcr.io/resultcrafter/cline-kanban .`
- [x] 4.4 Build ZAI image step: `docker build -f Dockerfile.zai -t ghcr.io/resultcrafter/cline-kanban-zai .` (only after base is pushed so it can FROM it)
- [x] 4.5 Tag logic: on `main` push → tag both images with `main`; on `v*` tag → tag with version + `latest`
- [x] 4.6 Login to GHCR using `GITHUB_TOKEN`, push both images
- [x] 4.7 Add Node.js setup + npm ci + web-ui npm ci before build (as pre-build validation)

## 5. Remove Slack notification from publish workflow

- [x] 5.1 Remove the "Post release to Slack" step (lines ~143-161) from `.github/workflows/publish.yml`

## 6. Update deployment documentation

- [x] 6.1 Update `kb/cline-cloudcli-manual.md` with new `podman run` command using `ghcr.io/resultcrafter/cline-kanban:latest` (base) or `ghcr.io/resultcrafter/cline-kanban-zai:latest` (ZAI)
- [x] 6.2 Document the two-image architecture: base image vs ZAI extension
- [x] 6.3 Document `Z_AI_API_KEY` env var — only relevant for the ZAI extension image
- [x] 6.4 Add GHCR login instructions for the deployment host
- [x] 6.5 Remove references to the old `cline-kanban-docker` repo and manual `podman build`

## 7. Verify

- [ ] 7.1 Build the base Dockerfile locally: `podman build -t localhost/cline-kanban:test .`
- [ ] 7.2 Run the base container and verify kanban starts, nginx proxies, WebSocket connects
- [ ] 7.3 Build the ZAI extension locally: `podman build -f Dockerfile.zai -t localhost/cline-kanban-zai:test .`
- [ ] 7.4 Run the ZAI container with `Z_AI_API_KEY` set, verify MCP servers appear in `.claude.json`
- [ ] 7.5 Push the branch, verify the GHCR workflow triggers and pushes both images
