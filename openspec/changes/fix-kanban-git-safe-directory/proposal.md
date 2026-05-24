## Why

The kanban container runs as user `kanban` (UID 999) via `gosu`, but project repos are bind-mounted from the host with different ownership (host UID 0). Git's `safe.directory` check (introduced in git 2.35.2) rejects repos owned by a different UID, causing:

1. **Kanban server can't load workspace state** — `git -C /projects/geo-audit-adk status` fails with "dubious ownership"
2. **Only `aimanager-telegram-webhook` works** — it was `git clone`'d inside the container by the kanban user
3. **UI shows infinite spinner** — project list loads from `index.json` (file-based, works), but subsequent git-dependent tRPC/WS calls fail silently

The entrypoint's `is_git_repo()` bypasses this (it checks `[ -d .git ]` first), so project registration succeeds. But the kanban Node.js server's actual git operations fail.

## What Changes

- Add `git config --global --add safe.directory '*'` to the entrypoint, written to `/home/kanban/.gitconfig` before the kanban server starts
- Place it in `fix_permissions()` or a new dedicated function, ensuring it runs after the kanban user's home directory is set up

## Capabilities

### Modified Capabilities
- `container-entrypoint`: Configure git `safe.directory` wildcard for the kanban user so bind-mounted repos are accessible

## Impact

- Modified: `docker/entrypoint.sh` — add 1-2 lines to configure git safe.directory for kanban user
- No changes to `Dockerfile`, `Dockerfile.zai`, or `entrypoint-zai.sh`
