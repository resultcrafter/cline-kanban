## Context

The kanban app is a Node.js ESM app built with esbuild. Build output goes to `dist/` with `dist/cli.js` as the entry point and `dist/web-ui/` for the frontend. The app depends on `node-pty` (native addon) which requires compilation at install time. The current container runs `npx --yes kanban@latest --host 127.0.0.1 --port 3485` behind an nginx reverse proxy on port 3484.

The existing container image includes nginx, gosu (user switching), git, claude-code CLI, and opencode CLI — all tools needed for the kanban agent workspace environment.

GitHub repo: `resultcrafter/cline-kanban`

## Goals / Non-Goals

**Goals:**
- Container image builds from source in CI — no npm publish dependency
- Image published to `ghcr.io/resultcrafter/cline-kanban` automatically
- Deployment host pulls pre-built image from GHCR
- Preserve all existing container functionality (nginx, basic auth, project registration, claude-code, opencode)
- Remove Slack notification from publish workflow

**Non-Goals:**
- Changing the npm publish workflow itself (it stays for npm consumers)
- Multi-arch builds (amd64 only for now — the deployment host is x86_64)
- Changing the nginx proxy configuration or entrypoint behavior
- Adding Kubernetes or docker-compose deployment manifests

## Decisions

### 1. Multi-stage Dockerfile in the source repo

```
Stage 1 (builder):  node:22-slim → npm ci → npm run build → produces dist/
Stage 2 (runtime):  node:22-slim → install system deps → COPY dist/ → run
```

This keeps the runtime image small. The builder stage has all devDependencies for compilation; the runtime stage only has production dependencies and the built output.

### 2. `node-pty` handled in builder stage

`node-pty` is a native addon compiled during `npm ci`. It's listed as a regular dependency (not optional) so the builder must compile it. We use `npm ci --omit=dev` in the runtime stage for production deps, then overlay the compiled `node-pty` binding from the builder.

Alternative considered: install `node-pty` in runtime stage too. Rejected — would require build-essential + python in runtime image, bloating it.

### 3. GHCR workflow triggers

- **Push to `main`**: Build and push `ghcr.io/resultcrafter/cline-kanban:main` (dev tag)
- **Tag `v*`**: Build and push `ghcr.io/resultcrafter/cline-kanban:vX.Y.Z` + `latest`
- **Manual (workflow_dispatch)**: Build and push with a custom tag

### 4. Docker files in `docker/` subdirectory

The Dockerfile itself lives at the repo root (needed for Docker build context to access `src/`, `web-ui/`, `package.json`). Supporting files (entrypoint.sh, nginx.conf.template) live in `docker/`.

### 5. Nginx + gosu preserved from existing container

The nginx reverse proxy is essential for WebSocket upgrade handling and optional basic auth. `gosu` runs the kanban process as a non-root user. Both are carried forward from the existing container.

### 6. Remove Slack notification from publish.yml

The `Post release to Slack` step (lines 143-161 in publish.yml) is removed. The npm publish and GitHub release steps remain unchanged.

### 7. Separate base and ZAI images — `Dockerfile` + `Dockerfile.zai`

Two Dockerfiles with a clean inheritance boundary:

**`Dockerfile` (base image):** Builds kanban from source, includes nginx, gosu, claude-code, opencode. No vendor-specific packages or configuration. Published as `ghcr.io/resultcrafter/cline-kanban`.

**`Dockerfile.zai` (ZAI extension):** Starts `FROM` the base image. Installs `@z_ai/mcp-server` globally. Uses a separate `docker/entrypoint-zai.sh` that calls the base entrypoint, then configures MCP servers in `.claudejson` when `Z_AI_API_KEY` is set. Published as `ghcr.io/resultcrafter/cline-kanban-zai`.

```
Dockerfile          →  ghcr.io/resultcrafter/cline-kanban       (base)
                           │
Dockerfile.zai  FROM ────→  ghcr.io/resultcrafter/cline-kanban-zai (ZAI extension)
```

This separation means:
- The base image is vendor-neutral — usable by anyone without ZAI
- ZAI-specific logic is isolated in one Dockerfile + one entrypoint
- The base image can be built and tested independently
- Adding other vendor extensions later follows the same pattern (e.g., `Dockerfile.openai`)

## Risks / Trade-offs

- **`node-pty` version mismatch**: The native addon compiled in the builder must match the Node.js version and glibc in the runtime. Using the same `node:22-slim` base for both stages eliminates this risk.
- **Image size**: Including claude-code (~306MB) and opencode (~144MB) makes the image large (~1GB+). These are needed for the agent workspace. Could be made optional in a future change.
- **GHCR authentication on deployment host**: The host needs `podman login ghcr.io` with a PAT that has `read:packages` scope. The image can be made public to avoid this.
- **No multi-arch**: Only amd64 for now. If ARM deployment is needed later, add QEMU + buildx matrix.
- **`@z_ai/mcp-server` package adds ~10MB** but only to the ZAI extension image (`clline-kanban-zai`), not the base image. The base stays clean.
