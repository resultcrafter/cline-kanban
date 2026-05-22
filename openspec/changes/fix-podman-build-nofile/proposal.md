## Why

The base Dockerfile in the `add-ghcr-container-build` change fails during `podman build` on the deployment host. The `vite build` step inside the builder stage reports random npm packages as missing (e.g., `posthog-js`, `@radix-ui/primitive`, `react-hotkeys-hook`), with only ~20 modules transformed instead of the expected 3217.

After extensive investigation (documented in `add-ghcr-container-build/investigation-podman-nofile.md`), the root cause is that **`podman build` processes have a file descriptor limit (`nofile`) of 1024** — far too low for npm's `node_modules` (400+ packages, thousands of files and symlinks) combined with vite's module resolution. `podman run` and Docker Engine both use much higher limits (524288 and 1048576 respectively).

## What Changes

- Add `--ulimit nofile=131072:1048576` to the `podman build` command used to build the container image locally on the deployment host
- Clean up the temporary `docker/build-inner.sh` and `docker/build.sh` files that were created during investigation
- Restore the Dockerfile builder stage to a clean two-step pattern: `COPY . .` then `RUN npm ci && npm ci --prefix web-ui && npm run build`
- Document the `--ulimit` requirement in deployment docs

## Capabilities

### Modified Capabilities
- `container-build-local`: Local `podman build` on the deployment host must use `--ulimit nofile=131072:1048576` to avoid fd exhaustion during vite build

## Impact

- Modified: `Dockerfile` — restore clean builder stage (remove investigation workarounds)
- Deleted: `docker/build-inner.sh` — temporary workaround file
- Deleted: `docker/build.sh` — temporary workaround file
- Modified: `kb/cline-cloudcli-manual.md` — add `--ulimit` flag to the `podman build` command
- No changes to GitHub Actions CI (uses Docker, not podman — unaffected)
