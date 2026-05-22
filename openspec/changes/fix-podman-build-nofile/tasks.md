## 1. Clean up investigation artifacts

- [x] 1.1 Delete `docker/build-inner.sh`
- [x] 1.2 Delete `docker/build.sh`

## 2. Restore Dockerfile to clean builder stage

- [x] 2.1 Replace the builder stage in `Dockerfile` with the clean pattern: `COPY . .` then `RUN npm ci && npm ci --prefix web-ui && npm run build`

## 3. Build and verify locally

- [ ] 3.1 Run `podman build --ulimit nofile=131072:1048576 --no-cache -t localhost/cline-kanban:test .` — verify vite transforms 3217 modules and build succeeds
- [ ] 3.2 Verify the runtime stage completes (claude-code install, opencode download, dist copy)

## 4. Update deployment documentation

- [ ] 4.1 Update `kb/cline-cloudcli-manual.md` to include `--ulimit nofile=131072:1048576` in the local `podman build` command
- [ ] 4.2 Add a note explaining the podman nofile limitation (reference the investigation doc)
