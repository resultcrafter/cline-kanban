## 1. Add `configure_git_safe_directory()` to entrypoint

- [x] 1.1 Add function `configure_git_safe_directory()` to `docker/entrypoint.sh` that writes `safe.directory = *` to `/home/kanban/.gitconfig` using `git config -f`, then `chown` to `kanban:kanban`
- [x] 1.2 Add `configure_git_safe_directory` call in the entrypoint sequence, after `fix_permissions` and before the nginx/kanban startup block

## 2. Verify

- [x] 2.1 Commit, push to a branch, verify CI builds both images
- [x] 2.2 Pull new image, recreate container, verify `podman exec -u kanban cline-kanban git -C /projects/geo-audit-adk status` succeeds
- [x] 2.3 Verify all 7 projects appear in the UI without infinite spinner
- [x] 2.4 Update system-setup incident with resolution
