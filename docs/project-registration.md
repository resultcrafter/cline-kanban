# Project Registration & Workspace Mounting

How to add new projects to Cline Kanban and configure workspace mounts.

---

## Architecture

```
Host filesystem                     Container filesystem
─────────────────                   ────────────────────
/shared-workspaces/        ──►      /projects/
  geo-audit-adk/                     geo-audit-adk/
  resultcrafter-services/            resultcrafter-services/
    buddy-session-service/             buddy-session-service/
    ...

/root/.kanban/.env  (──env-file──►  container env vars)
kanban-data volume   (──mount───►   /home/kanban/.cline)
```

**Key paths inside container:**

| Path | Purpose |
|---|---|
| `/projects/` | Mount point for git repos (bind-mounted from host) |
| `/home/kanban/.cline/` | Kanban state (persisted via `kanban-data` volume) |
| `/home/kanban/.cline/kanban/workspaces/index.json` | Workspace registry |
| `/home/kanban/.gitconfig` | Git config (NOT persisted, use env vars) |
| `/entrypoint.sh` | Startup script that registers projects |

---

## Adding a New Project

### 1. Prepare the repo on the host

The project must be a git repository on the host under `/shared-workspaces/`:

```bash
# Ensure the repo exists and has .git
ls /shared-workspaces/<project-name>/.git
```

If the project is nested (e.g. a monorepo subdirectory), use the full path:

```bash
/shared-workspaces/resultcrafter-services/buddy-session-service/
```

### 2. Add to KANBAN_PROJECTS env var

Edit `/root/.kanban/.env` and append the path (comma-separated):

```bash
KANBAN_PROJECTS=/projects/geo-audit-adk,/projects/new-project-name
```

**Important**: Use the container-internal path (`/projects/...`), not the host path (`/shared-workspaces/...`). The entrypoint reads this env var inside the container.

### 3. Recreate the container

The entrypoint only runs at container start. You must recreate (not restart) to pick up the new `KANBAN_PROJECTS` value:

```bash
podman rm -f cline-kanban

podman run -d \
  --name cline-kanban \
  --restart=unless-stopped \
  --network=host \
  --env-file /root/.kanban/.env \
  -v kanban-data:/home/kanban/.cline \
  -v /shared-workspaces:/projects:rw \
  ghcr.io/resultcrafter/cline-kanban-zai:main
```

### 4. Verify registration

```bash
# Check logs for "Registered project:" line
podman logs cline-kanban 2>&1 | grep "Registered project"

# Verify API returns the new project
curl -s "http://127.0.0.1:3484/api/trpc/projects.list" | python3 -m json.tool

# Verify workspace mutations work
curl -s -X POST "http://127.0.0.1:3484/api/trpc/runtime.startTaskSession" \
  -H "Content-Type: application/json" \
  -H "x-kanban-workspace-id: new-project-name" \
  -d '{"json":{"workspaceId":"new-project-name","task":"hello","agentId":"cline"}}'
```

---

## Workspace ID Rules

The entrypoint generates workspace IDs from the directory basename:

| Host path | Container path | Workspace ID |
|---|---|---|
| `/shared-workspaces/geo-audit-adk` | `/projects/geo-audit-adk` | `geo-audit-adk` |
| `/shared-workspaces/resultcrafter-services/buddy-session-service` | `/projects/resultcrafter-services/buddy-session-service` | `buddy-session-service` |

**Collision handling**: If two repos have the same basename, the entrypoint appends a suffix (e.g., `project-abc123`).

---

## Required Environment Variables

These must be in `/root/.kanban/.env` for proper operation:

```bash
# Core
KANBAN_NO_AUTO_UPDATE=1
ANTHROPIC_API_KEY=<key>
ANTHROPIC_BASE_URL=<url>
ANTHROPIC_MODEL=<model>

# Project list (container paths, comma-separated)
KANBAN_PROJECTS=/projects/geo-audit-adk,/projects/resultcrafter-services/buddy-session-service

# Git safe directory (CRITICAL — without this, workspace mutations fail)
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=safe.directory
GIT_CONFIG_VALUE_0=*

# Optional: ZAI MCP integration
# Z_AI_API_KEY=<key>
```

---

## Volume Mounts

### kanban-data (named volume → /home/kanban/.cline)

Persists kanban state across container recreation:

- `data/db/sessions.db` — Session database
- `data/sessions/` — Session history files
- `data/settings/` — Provider settings
- `kanban/workspaces/index.json` — Workspace registry
- `kanban/workspaces/<id>/` — Per-workspace state (boards, configs)

**Warning**: Removing this volume (`podman volume rm kanban-data`) destroys all session history and workspace state.

### /shared-workspaces → /projects (bind mount)

Read-write bind mount of host directory. All git repos here are visible to kanban agents.

**Permissions**: The repos must be readable (and writable, for agents that commit) by UID 999 (`kanban` user inside container). On the host:

```bash
# Make repos readable by all (simple approach)
chmod -R a+rX /shared-workspaces/<repo>

# Or use ACLs for precise control
setfacl -R -m u:999:rwx /shared-workspaces/<repo>
```

---

## Auto-Discovery vs Explicit List

The entrypoint supports two modes:

**Explicit list** (recommended): Set `KANBAN_PROJECTS` env var with comma-separated paths. Only listed repos are registered.

**Auto-discovery**: If `KANBAN_PROJECTS` is unset, the entrypoint scans `/projects/*/` for git repos and registers all of them.

---

## Troubleshooting Registration Failures

### "Skipping non-git directory"

The entrypoint skips directories without a `.git` subdirectory:

```bash
# Verify .git exists
podman exec cline-kanban ls /projects/<name>/.git/HEAD
```

### "WARNING: KANBAN_PROJECTS path not found"

The path in `KANBAN_PROJECTS` doesn't exist inside the container. Check:
- Using container paths (`/projects/...`) not host paths (`/shared-workspaces/...`)
- Bind mount is correct (`-v /shared-workspaces:/projects`)
- Path doesn't have trailing slashes or spaces

### Projects registered but mutations return 404

See [INC-001 in incidents.md](./incidents.md#inc-001-unknown-workspace-id-on-all-mutations-after-container-recreation) — likely the `GIT_CONFIG_*` env vars are missing.

### Index.json exists but server ignores it

The server loads the index into memory at startup. After manually editing `index.json`, restart the container:

```bash
podman restart cline-kanban
```
