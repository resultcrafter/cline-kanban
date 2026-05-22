## Why

The cline-kanban container is currently built from a separate private repo (`cline-kanban-docker`) that wraps `npx --yes kanban@latest` — downloading the npm package at container startup. This means:

1. **Source changes require npm publish to deploy** — the publish workflow gates all deployments, including Slack notifications
2. **Every container start downloads from npmjs.org** — slow startup, depends on npm availability
3. **No CI/CD for the container image** — image is built manually with `podman build` on the host
4. **The separate Docker repo is gone from disk** — `/root/cline-kanban-docker/` no longer exists

We need a self-contained build pipeline where the container image is built from source in GitHub Actions and published to GHCR (GitHub Container Registry). The deployment host then pulls the image directly — no npm publish needed.

## What Changes

- Add a multi-stage `Dockerfile` to the cline-kanban source repo that builds the app from source and runs it directly via `node dist/cli.js` — this is the **base image** containing only kanban + claude-code + opencode + nginx
- Add an optional `Dockerfile.zai` that extends the base image with ZAI MCP tools — pre-installs `@z_ai/mcp-server`, adds MCP server config to `.claude.json` at startup when `Z_AI_API_KEY` is set
- Add a GitHub Actions workflow (`container.yml`) that builds both images and pushes to GHCR: `ghcr.io/resultcrafter/cline-kanban` (base) and `ghcr.io/resultcrafter/cline-kanban-zai` (ZAI extension)
- Port the nginx reverse proxy, entrypoint logic, and basic auth from the old `cline-kanban-docker` repo
- Remove the Slack notification step from the publish workflow
- Update the deployment run command to pull from GHCR instead of building locally

## Capabilities

### New Capabilities
- `container-build`: CI pipeline that builds container images from source and publishes to GHCR
- `container-image`: Self-contained base Dockerfile that builds kanban from source without npm — no vendor-specific logic
- `container-image-zai`: Optional extended image (`Dockerfile.zai`) that adds ZAI MCP tools on top of the base image

### Modified Capabilities
- `publish-workflow`: Remove Slack notification step from the publish workflow

## Impact

- New file: `Dockerfile` at repo root — base image (kanban + claude-code + opencode + nginx)
- New file: `Dockerfile.zai` at repo root — optional ZAI extension (inherits base, adds MCP tools)
- New file: `.github/workflows/container.yml`
- New file: `docker/entrypoint.sh` — base entrypoint (nginx, basic auth, project registration, claude auth)
- New file: `docker/entrypoint-zai.sh` — ZAI entrypoint (calls base entrypoint, then configures MCP servers if `Z_AI_API_KEY` is set)
- New file: `docker/nginx.conf.template` — nginx reverse proxy template
- Modified: `.github/workflows/publish.yml` — remove Slack notification step
- Deployment: `podman run` uses `ghcr.io/resultcrafter/cline-kanban:latest` (base) or `ghcr.io/resultcrafter/cline-kanban-zai:latest` (with ZAI)
