## Context

The deployment host runs podman 4.9.3 on Ubuntu 22.04. The base Dockerfile uses a multi-stage build: stage 1 (builder) runs `npm ci` + `vite build` in `node:22-slim`, stage 2 (runtime) copies the built `dist/` into a production image. The `vite build` step resolves ~3217 ES modules from `web-ui/node_modules/` (416 npm packages).

Podman 4.9.3 on Ubuntu 22.04 applies a `nofile=1024` ulimit to `podman build` processes by default, regardless of the host's ulimit. Docker Engine defaults to `nofile=1048576`. This is documented at https://devops.stackexchange.com/questions/18215.

## Goals / Non-Goals

**Goals:**
- Make `podman build` succeed on the deployment host
- Clean up investigation artifacts (temporary build scripts)
- Document the fix so it's not rediscovered

**Non-Goals:**
- Changing the GitHub Actions CI workflow (uses Docker, unaffected)
- Upgrading podman or switching to Docker on the host
- Modifying the `.dockerignore` or npm dependency structure

## Decisions

### 1. Use `--ulimit nofile=131072:1048576` on `podman build`

```bash
podman build --ulimit nofile=131072:1048576 -t localhost/cline-kanban:test .
```

131072 soft limit is sufficient for the largest expected module resolution workload. 1048576 hard limit matches Docker's default. This is a command-line flag only — no system config changes needed.

Alternative considered: editing `/etc/containers/containers.conf` with `default_ulimits = ["nofile=16384:524288"]`. Rejected because it affects all containers on the host, not just builds. The CLI flag is targeted and explicit.

### 2. Restore Dockerfile to clean two-step builder

The Dockerfile builder stage should be:

```dockerfile
COPY . .
RUN npm ci && npm ci --prefix web-ui && npm run build
```

This is the simplest pattern: copy all source, install deps, build. The `.dockerignore` excludes `node_modules` so there's no overwrite risk. The `--ulimit` flag resolves the fd exhaustion.

### 3. Delete temporary investigation files

Remove `docker/build-inner.sh` and `docker/build.sh` — these were created during debugging and are no longer needed.

## Risks / Trade-offs

- **CI unaffected**: GitHub Actions uses Docker Engine with `nofile=1048576`, so no `--ulimit` needed there
- **Future podman versions**: Newer podman versions (5.x+) support `--ulimit=host` for builds. If the host is upgraded, the explicit flag can be removed
- **No persistent config change**: The fix is a CLI flag, not a system config. If someone runs `podman build` without the flag, they'll hit the same issue. Documentation mitigates this
