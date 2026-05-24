## Context

The kanban container uses a two-process architecture: nginx (port 3484) reverse-proxying to the kanban Node.js server (port 3485). The entrypoint (`/entrypoint.sh`) runs as root, registers projects by writing to `index.json`, then launches the kanban server as user `kanban` (UID 999) via `gosu`.

Project repos are bind-mounted from the host via `-v /shared-workspaces:/projects`. These repos are owned by host UIDs (typically root, UID 0), creating an ownership mismatch with the container's `kanban` user (UID 999).

Git 2.35.2+ introduced the `safe.directory` check: if a repo's owner doesn't match the current user, git refuses to operate on it unless the directory is listed in `safe.directory` config.

## Goals / Non-Goals

**Goals:**
- Kanban server can perform git operations on all bind-mounted project repos
- Fix is minimal — single config line in the entrypoint
- Works for any UID mismatch, not just root → kanban

**Non-Goals:**
- Changing repo ownership on the host
- Adding individual repo paths to safe.directory (wildcard is appropriate for a container)
- Fixing the host-side mount permissions

## Decisions

### 1. Use `safe.directory = '*'` (wildcard)

```
git config --global --add safe.directory '*'
```

Written to `/home/kanban/.gitconfig` so it applies when the kanban server runs git commands as user `kanban`.

**Why wildcard:** The container only sees repos explicitly bind-mounted by the operator. There are no untrusted repos inside the container. Adding individual paths would require enumerating `KANBAN_PROJECTS` and duplicating logic already in `register_projects()`.

**Alternative considered:** `git config --system`. Rejected — system config applies to all users including root, and the entrypoint already runs as root where it doesn't need safe.directory.

### 2. Placement: new `configure_git_safe_directory()` function

Called in the entrypoint sequence after `fix_permissions()` but before starting nginx and kanban. This ensures `/home/kanban/.gitconfig` exists and is writable.

```
configure_git_safe_directory() {
    git config --global --add safe.directory '*'
    chown kanban:kanban /home/kanban/.gitconfig 2>/dev/null || true
    echo "[entrypoint] Git safe.directory configured for kanban user"
}
```

Wait — `git config --global` uses `$HOME`. The entrypoint runs as root, so `$HOME=/root`. We need to target the kanban user's gitconfig explicitly:

```
configure_git_safe_directory() {
    local gitconfig="/home/kanban/.gitconfig"
    git config -f "$gitconfig" --add safe.directory '*'
    chown kanban:kanban "$gitconfig" 2>/dev/null || true
    echo "[entrypoint] Git safe.directory configured for kanban user"
}
```

Using `git config -f` targets the file directly regardless of current `$HOME`.

### 3. No changes to `is_git_repo()` in entrypoint

The entrypoint's `is_git_repo()` already works because it falls through to `[ -d "$1/.git" ]` which doesn't invoke git. No change needed there.

## Risks / Trade-offs

- **Wildcard `*` is broad** — but acceptable in a container where all repos are operator-provided. This is the same approach used by GitHub Actions runners and many CI containers.
- **If gitconfig already exists** — `--add` appends rather than overwrites, so existing config is preserved. Duplicate entries are harmless (git ignores them).
- **No rebuild needed** — this is an entrypoint change only. The existing GHCR image can be patched by just updating `docker/entrypoint.sh` and rebuilding.
