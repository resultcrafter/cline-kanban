## Context

The deployment host runs podman 4.9.3 on Ubuntu 22.04. The current `cline-kanban` container runs an old `localhost/cline-kanban:latest` image that uses `npx --yes kanban@latest` to download and run the app at startup. The new image (built from `Dockerfile`) compiles from source at build time — no npm download at runtime.

The GitHub Actions workflow `container.yml` is already written and will trigger on push to `main` and on `v*` tags. It uses Docker Buildx with GHA caching. CI builds will work because Docker Engine doesn't have the `nofile` limitation that podman 4.9.3 has.

Two branches need to land on `main`:
1. `add-ghcr-container-build` — Dockerfile, docker/*, container.yml, .dockerignore, publish.yml (Slack removed)
2. `fix-ws-disconnect-ping-pong` — WebSocket keepalive (ping/pong) fix

The `fix-podman-build-nofile` change (adding `--ulimit nofile` to podman build) is no longer needed since we're delegating all builds to CI.

## Goals / Non-Goals

**Goals:**
- Get the container image built and published via CI
- Deploy the GHCR image on the host
- Stop fighting podman's nofile limit locally

**Non-Goals:**
- Making local podman build work (the nofile fix is abandoned)
- Changing the CI workflow (it's already correct)
- Changing the Dockerfile (it works in Docker Engine)
- Multi-arch builds

## Decisions

### 1. Merge both branches, let CI do the build

Push `add-ghcr-container-build` to `main` (or merge via PR). The `container.yml` workflow triggers automatically. No local build needed.

The `fix-ws-disconnect-ping-pong` branch should also be merged — it contains the WebSocket keepalive fix that prevents CF Tunnel idle disconnects. Both branches are independent (different files).

### 2. Pull image from GHCR on deployment host

```bash
podman pull ghcr.io/resultcrafter/cline-kanban-zai:latest
```

If the GHCR package is private, login first:
```bash
echo "<PAT>" | podman login ghcr.io -u resultcrafter --password-stdin
```

### 3. Replace the running container

```bash
podman stop cline-kanban
podman rm cline-kanban
podman run -d \
  --name cline-kanban \
  --restart=unless-stopped \
  --network=host \
  --env-file /root/.kanban/.env \
  -e Z_AI_API_KEY=<key> \
  -v kanban-data:/home/kanban/.cline \
  -v /shared-workspaces:/projects \
  ghcr.io/resultcrafter/cline-kanban-zai:latest
```

The existing `kanban-data` volume is preserved (contains `.cline/` config, workspaces, settings).

### 4. Cancel `fix-podman-build-nofile` change

The `--ulimit nofile` workaround is no longer needed since we're not building locally. Mark the change as cancelled.

### 5. GHCR package visibility

Set the GHCR package to **public** so the deployment host can pull without authentication. This avoids managing PAT tokens on the host. The image doesn't contain secrets (API keys are runtime env vars).

## Risks / Trade-offs

- **No local build path**: If CI is down or we need to test Dockerfile changes locally, we're stuck with the podman nofile issue. Mitigation: use `podman build --ulimit nofile=131072:1048576` if we ever need to build locally (the fix from the cancelled change still works, it's just not documented as a primary path).
- **GHCR availability**: Deployment depends on GHCR being reachable. This is comparable to the current npmjs.org dependency. GHCR has very high uptime.
- **First build takes time**: CI will need to build the image from scratch (no cache on first run). Subsequent builds use GHA cache.
- **`Dockerfile.zai` needs base image published first**: The ZAI Dockerfile does `FROM ghcr.io/resultcrafter/cline-kanban:latest` — the base image must be pushed to GHCR before the ZAI image can build. The `container.yml` workflow handles this ordering (base builds before ZAI).
