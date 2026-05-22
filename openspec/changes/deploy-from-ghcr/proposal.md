## Why

The `add-ghcr-container-build` branch has a working `Dockerfile`, `Dockerfile.zai`, and `container.yml` workflow — but we've been blocked for days trying to build the image locally with `podman build`. The root cause is podman 4.9.3's `nofile=1024` limit in build processes, which causes vite to fail with random missing modules.

This is a waste of time. GitHub Actions uses Docker Engine (which has `nofile=1048576`), so CI builds will work fine. The local podman build was only ever a verification step — the actual deployment path has always been "CI builds → GHCR → host pulls."

We should stop trying to fix podman locally and instead:
1. Push the branch, merge to `main`, let CI build and publish to GHCR
2. Pull the image from GHCR on the deployment host
3. Switch the running container from the old `localhost/cline-kanban:latest` (npx-based) to the GHCR image

## What Changes

- Merge the `add-ghcr-container-build` branch (Dockerfile, Dockerfile.zai, container.yml, docker/*, .dockerignore)
- Merge the `fix-ws-disconnect-ping-pong` branch (WebSocket keepalive fix)
- Ensure GHCR packages are public (or configure `podman login ghcr.io` on the host)
- Stop the old container, pull the new image from GHCR, start a new container
- Update the `.env` file and `podman run` command to use the GHCR image
- Archive both completed changes

## Capabilities

### Modified Capabilities
- `container-deployment`: Host pulls pre-built image from GHCR instead of building locally with podman

## Impact

- No new files (all changes already exist on branches)
- Deployment: `podman stop cline-kanban && podman rm cline-kanban && podman pull ghcr.io/resultcrafter/cline-kanban-zai:latest && podman run ...`
- The old `localhost/cline-kanban:latest` image becomes obsolete
- The `fix-podman-build-nofile` change is cancelled (no longer needed)
