# Investigation: Podman Build Fails — node_modules Files Missing During vite Build

**Date:** 2026-05-22
**Status:** Root cause identified, fix proposed

## Symptom

`podman build` fails during `npm run build` (specifically at the `vite build` step inside `web-ui/`). A random npm dependency is reported as missing each time:

```
[vite]: Rollup failed to resolve import "posthog-js" from "/build/web-ui/node_modules/@posthog/react/dist/esm/index.js".
```

Only **~20-30 modules** are transformed by vite, vs **3217** when the build succeeds.

## What We Tried

| Attempt | Result |
|---------|--------|
| Single `RUN` with combined `npm ci && npm ci --prefix web-ui && npm run build` | Failed (random dep missing) |
| Separate `RUN` steps (install then build) | Failed (overlay layer doesn't carry node_modules) |
| `npm install` instead of `npm ci` | Failed (same issue) |
| `npm ci --foreground-scripts=false` | Failed |
| `sync` calls between steps | Failed |
| Shell script wrapper (`docker/build-inner.sh`) | Failed |
| 3-stage build with tar-based node_modules transfer | Timed out (COPY too large) |
| `--format docker` | Failed |
| `--userns host` | Failed |
| Interactive container with `podman run -v` volume mount | **Succeeded** (3217 modules) |
| Running `npm ci` + `vite build` manually inside cached builder layer | **Succeeded** (3217 modules) |

## Root Cause

**`podman build` processes have a file descriptor (`nofile`) limit of 1024.**

This is a known issue documented on [DevOps StackExchange](https://devops.stackexchange.com/questions/18215/processes-in-podman-build-have-lower-file-descriptor-limit-than-processes-in):

- `podman build` → `nofile=1024`
- `podman run` → inherits host limit (e.g., `nofile=524288`)
- Docker Engine → `nofile=1048576` for both build and run

With npm's `node_modules` containing 400+ packages (thousands of files and symlinks), vite needs to open far more than 1024 file descriptors during module resolution. When the limit is hit, file reads silently fail, causing random "module not found" errors.

### Why it's non-deterministic

The order in which vite resolves imports, and which files happen to be already open, varies slightly between runs. This means different packages exceed the fd limit at different points, causing different "missing" packages each time.

### Why volume mount works

`podman run -v` uses the host filesystem directly (not overlay), and the process inherits the host's `nofile=524288` limit. No fd exhaustion.

## Fix

**Option 1 (recommended):** Pass `--ulimit nofile=131072:1048576` to `podman build`:
```bash
podman build --ulimit nofile=131072:1048576 -t localhost/cline-kanban:test .
```

**Option 2 (persistent):** Set in `/etc/containers/containers.conf`:
```toml
[containers]
default_ulimits = ["nofile=16384:524288"]
```

**Option 3:** Install Docker Engine instead (doesn't have this limitation).

## References

- [DevOps SE: Processes in podman build have lower file descriptor limit](https://devops.stackexchange.com/questions/18215/processes-in-podman-build-have-lower-file-descriptor-limit-than-processes-in)
- [Podman issue #2053: File descriptor limit applies to entire container](https://github.com/containers/podman/issues/2053)
- [Arch Linux BBS: Podman crawls on npm install after upgrade to 5.0.0](https://bbs.archlinux.org/viewtopic.php?id=294205)
