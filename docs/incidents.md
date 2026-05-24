# Incident Log & Troubleshooting Guide

Operational incidents and resolution steps for Cline Kanban deployments.

---

## INC-001: "Unknown workspace ID" on all mutations after container recreation

**Date**: 2026-05-22
**Severity**: High — all `workspaceProcedure` mutations broken
**Symptoms**: `projects.list` returns workspaces, but `runtime.startTaskSession`, `runtime.sendChatMessage` etc. return HTTP 404 `"Unknown workspace ID: <id>"`.

### Root Cause

Git's `safe.directory` ownership check. Project repos mounted into the container are owned by the host user (UID 10000), but the kanban server process runs as UID 999 (`kanban` user via `gosu`). When `detectGitRoot()` runs `git rev-parse --show-toplevel`, git refuses with:

```
fatal: detected dubious ownership in repository at '/projects/<repo>'
```

The `workspaceProcedure` middleware calls `loadWorkspaceContextById()` → `loadWorkspaceContext()` → `resolveWorkspacePath()` → `detectGitRoot()`. When `detectGitRoot` returns `null`, `resolveWorkspacePath` throws `"No git repository detected"`, which is caught and returns `null` for `workspaceScope`, triggering the 404.

**Key insight**: `projects.list` works because it uses `t10.procedure` (no workspace middleware), while all mutations use `workspaceProcedure` which requires `ctx.workspaceScope`.

### Resolution

Add git safe directory config via environment variables (survives container recreation):

```bash
# In the container's env file (e.g. /root/.kanban/.env)
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=safe.directory
GIT_CONFIG_VALUE_0=*
```

Or inside a running container (does NOT survive recreation):

```bash
podman exec cline-kanban gosu kanban git config --global --add safe.directory '*'
```

### Verification

```bash
# Should return the repo path, not "dubious ownership"
podman exec cline-kanban gosu kanban git -C /projects/<repo> rev-parse --show-toplevel

# Should return running session, not 404
curl -s -X POST "http://127.0.0.1:3484/api/trpc/runtime.startTaskSession" \
  -H "Content-Type: application/json" \
  -H "x-kanban-workspace-id: <workspace-id>" \
  -d '{"json":{"workspaceId":"<workspace-id>","task":"test","agentId":"cline"}}'
```

---

## INC-002: Workspace index.json empty after container restart

**Date**: 2026-05-22
**Severity**: Medium — workspace index wiped, but entrypoint re-registers projects

### Root Cause

The workspace index at `/home/kanban/.cline/kanban/workspaces/index.json` is NOT on a persisted volume. The `kanban-data` volume mounts at `/home/kanban/.cline` but the entrypoint recreates `index.json` on every start. If the entrypoint's `merge_into_workspace_index()` function encounters any issue (missing `jq`, wrong paths), the index remains empty `{"version":1,"entries":{},"repoPathToId":{}}`.

The server reads `index.json` into memory at startup and does not re-read it. Even if you fix the file on disk, the server's in-memory index stays empty until restart.

### Resolution

1. Verify the entrypoint registers projects (check logs for `"Registered project:"` lines):
   ```bash
   podman logs --tail 50 cline-kanban 2>&1 | grep "Registered project"
   ```

2. If missing, verify the project paths in `KANBAN_PROJECTS` env var match actual directories with `.git`:
   ```bash
   podman exec cline-kanban bash -c 'for p in $(echo $KANBAN_PROJECTS | tr "," "\n"); do
     echo "$p: $(test -d $p/.git && echo "HAS .git" || echo "NO .git")"
   done'
   ```

3. If the index file exists but server has stale in-memory copy, restart the container:
   ```bash
   podman restart cline-kanban
   ```

### Diagnostic: Manually verify index.json

```bash
podman exec cline-kanban cat /home/kanban/.cline/kanban/workspaces/index.json | python3 -m json.tool
```

Each entry must have `workspaceId`, `repoPath`, and `name` fields. The `repoPathToId` map must contain reverse mappings.

---

## INC-003: "All projects are lost" after opening web UI

**Date**: 2026-05-22
**Severity**: Low — cosmetic, projects still exist in API

### Root Cause

The web UI displays workspaces from `projects.list` API. If the `currentProjectId` doesn't match a valid workspace, or if the workspace state files are missing (after container recreation with fresh volume), the UI may show an empty state.

### Resolution

1. Verify API returns projects:
   ```bash
   curl -s "http://127.0.0.1:3484/api/trpc/projects.list" | python3 -m json.tool
   ```

2. If projects are present in API but missing in UI, clear browser cache / hard reload.

3. If `currentProjectId` is stale, it self-corrects when you select a project in the UI.

---

## INC-004: ZAI MCP not configured (missing Z_AI_API_KEY)

**Date**: 2026-05-22
**Severity**: Low — optional feature

### Symptom

```
[entrypoint-zai] Z_AI_API_KEY not set, skipping ZAI MCP setup
```

### Resolution

Add `Z_AI_API_KEY` to the kanban env file if ZAI MCP integration is needed:

```bash
echo "Z_AI_API_KEY=<your-key>" >> /root/.kanban/.env
podman restart cline-kanban
```

---

## Quick Diagnostic Checklist

When kanban is misbehaving, run these in order:

```bash
# 1. Container running?
podman ps | grep cline-kanban

# 2. Server responding?
curl -s "http://127.0.0.1:3484/api/trpc/projects.list" | python3 -m json.tool

# 3. Git access for kanban user?
podman exec cline-kanban gosu kanban git -C /projects/<any-repo> rev-parse --show-toplevel

# 4. Workspace index populated?
podman exec cline-kanban cat /home/kanban/.cline/kanban/workspaces/index.json | python3 -m json.tool

# 5. Runtime config?
curl -s "http://127.0.0.1:3484/api/trpc/runtime.getConfig" | python3 -m json.tool

# 6. Recent logs?
podman logs --tail 30 cline-kanban 2>&1
```
