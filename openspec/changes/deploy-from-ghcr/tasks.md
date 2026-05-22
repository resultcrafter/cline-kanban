## 1. Merge branches to main

- [ ] 1.1 Push `add-ghcr-container-build` branch to origin (if not already pushed)
- [ ] 1.2 Push `fix-ws-disconnect-ping-pong` branch to origin (if not already pushed)
- [x] 1.3 Merge `fix-ws-disconnect-ping-pong` into `main` (WebSocket keepalive fix)
- [x] 1.4 Merge `add-ghcr-container-build` into `main` (Dockerfile, container.yml, docker/*)

## 2. Verify CI build

- [ ] 2.1 Confirm the `Container` workflow triggered on the merge to `main`
- [ ] 2.2 Wait for the build to succeed (base image + ZAI image)
- [ ] 2.3 Verify both images appear at `ghcr.io/resultcrafter/cline-kanban:main` and `ghcr.io/resultcrafter/cline-kanban-zai:main`
- [ ] 2.4 Set GHCR package visibility to Public (or configure podman login on host)

## 3. Deploy on host

- [ ] 3.1 Pull the ZAI image: `podman pull ghcr.io/resultcrafter/cline-kanban-zai:main`
- [ ] 3.2 Stop and remove the old container: `podman stop cline-kanban && podman rm cline-kanban`
- [ ] 3.3 Start new container from GHCR image with the same env vars and volumes
- [ ] 3.4 Verify kanban starts (check logs, nginx proxy, WebSocket)
- [ ] 3.5 Apply post-start fix: `podman exec -u kanban cline-kanban git config --global --add safe.directory '*'`

## 4. Cleanup

- [ ] 4.1 Tag a release (`v0.1.69` or similar) to trigger `v*` tag build with `latest` tag
- [ ] 4.2 Cancel the `fix-podman-build-nofile` change (no longer needed)
- [ ] 4.3 Archive completed changes (`add-ghcr-container-build`, `fix-ws-disconnect-ping-pong`, `deploy-from-ghcr`)
- [ ] 4.4 Remove old `localhost/cline-kanban:latest` image and dangling layers
