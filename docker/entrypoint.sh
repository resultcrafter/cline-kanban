#!/bin/bash
set -e

NGINX_TEMPLATE="/etc/nginx/nginx.conf.template"
NGINX_CONF="/etc/nginx/nginx.conf"
HTPASSWD_FILE="/etc/nginx/.htpasswd"
WORKSPACES_DIR="/home/kanban/.cline/kanban/workspaces"
INDEX_FILE="${WORKSPACES_DIR}/index.json"
CONFIG_FILE="/home/kanban/.cline/kanban/config.json"
CLAUDE_SETTINGS_DIR="/home/kanban/.claude"
CLAUDE_SETTINGS_FILE="${CLAUDE_SETTINGS_DIR}/settings.json"

setup_nginx() {
    local user="${BASIC_AUTH_USER:-}"
    local pass="${BASIC_AUTH_PASS:-}"

    cp "$NGINX_TEMPLATE" "$NGINX_CONF"

    if [ -n "$user" ] && [ -n "$pass" ]; then
        echo "[entrypoint] Enabling basic auth for user: $user"
        htpasswd -cbB "$HTPASSWD_FILE" "$user" "$pass"
        sed -i 's/#AUTH_BLOCK#//g' "$NGINX_CONF"
        sed -i 's|#AUTH_DIRECTIVE#|auth_basic "Kanban"; auth_basic_user_file /etc/nginx/.htpasswd;|g' "$NGINX_CONF"
    else
        echo "[entrypoint] Basic auth disabled (BASIC_AUTH_USER and BASIC_AUTH_PASS not set)"
        sed -i 's/#AUTH_BLOCK#//g' "$NGINX_CONF"
        sed -i 's/#AUTH_DIRECTIVE#//g' "$NGINX_CONF"
    fi

    if ! nginx -t 2>&1; then
        echo "[entrypoint] ERROR: nginx config validation failed"
        cat "$NGINX_CONF"
        exit 1
    fi
}

validate_nginx_conf() {
    local required_headers=("Host 127.0.0.1:3485" "X-Real-IP \$remote_addr" "X-Forwarded-For \$proxy_add_x_forwarded_for" "Upgrade \$http_upgrade" "Connection \$connection_upgrade")
    local ws_block
    ws_block=$(sed -n '/location.*runtime\/ws/,/^        }/p' "$NGINX_CONF")

    if [ -z "$ws_block" ]; then
        echo "[entrypoint] ERROR: Could not find WebSocket location block in nginx config"
        exit 1
    fi

    local missing=()
    if ! echo "$ws_block" | grep -qF 'proxy_set_header Host 127.0.0.1:3485'; then
        missing+=("Host 127.0.0.1:3485")
    fi
    if ! echo "$ws_block" | grep -qF 'proxy_set_header Origin ""'; then
        missing+=('Origin ""')
    fi
    for header in "X-Real-IP \$remote_addr" "X-Forwarded-For \$proxy_add_x_forwarded_for" "Upgrade \$http_upgrade" "Connection \$connection_upgrade"; do
        if ! echo "$ws_block" | grep -qF "proxy_set_header $header"; then
            missing+=("$header")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[entrypoint] ERROR: Missing proxy_set_header directives in WebSocket location block:"
        for h in "${missing[@]}"; do
            echo "  - proxy_set_header $h"
        done
        echo "[entrypoint] The generated nginx.conf may be stale. Rebuild with: docker compose build --no-cache"
        exit 1
    fi
    echo "[entrypoint] Nginx WebSocket proxy headers validated OK"
}

to_workspace_id() {
    local repo_path="$1"
    local basename
    basename=$(echo "$repo_path" | sed 's:/*$::' | xargs basename 2>/dev/null || echo "project")
    echo "$basename" | sed 's/[^a-z0-9]/-/g; s/^-*//; s/-*$//' | tr '[:upper:]' '[:lower:]'
}

generate_collision_suffix() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local suffix=""
    for i in 1 2 3 4; do
        suffix="${suffix}${chars:$((RANDOM % ${#chars})):1}"
    done
    echo "$suffix"
}

is_git_repo() {
    [ -d "$1/.git" ] || git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

merge_into_workspace_index() {
    local repo_path="$1"
    local workspace_id
    workspace_id=$(to_workspace_id "$repo_path")

    mkdir -p "$WORKSPACES_DIR"

    local existing_json="{}"
    if [ -f "$INDEX_FILE" ]; then
        existing_json=$(cat "$INDEX_FILE")
    fi

    local existing_wid
    existing_wid=$(echo "$existing_json" | jq -r ".repoPathToId[\"$repo_path\"] // empty" 2>/dev/null)

    if [ -n "$existing_wid" ]; then
        local has_entry
        has_entry=$(echo "$existing_json" | jq -r ".entries[\"$existing_wid\"] // empty" 2>/dev/null)
        if [ -n "$has_entry" ]; then
            return 0
        fi
    fi

    local final_id="$workspace_id"
    local occupied_entry
    occupied_entry=$(echo "$existing_json" | jq -r ".entries[\"$workspace_id\"].repoPath // empty" 2>/dev/null)
    if [ -n "$occupied_entry" ] && [ "$occupied_entry" != "$repo_path" ]; then
        final_id="${workspace_id}-$(generate_collision_suffix)"
    fi

    echo "$existing_json" | jq --arg id "$final_id" --arg path "$repo_path" '
        .version = (.version // 1) |
        .entries[$id] = {"workspaceId": $id, "repoPath": $path} |
        .repoPathToId[$path] = $id
    ' > "$INDEX_FILE.tmp" 2>/dev/null

    mv "$INDEX_FILE.tmp" "$INDEX_FILE"
    echo "[entrypoint] Registered project: $final_id -> $repo_path"
}

register_projects() {
    echo "[entrypoint] Registering projects..."

    local project_paths=""

    if [ -n "${KANBAN_PROJECTS:-}" ]; then
        IFS=',' read -ra paths <<< "$KANBAN_PROJECTS"
        for p in "${paths[@]}"; do
            p=$(echo "$p" | xargs)
            [ -z "$p" ] && continue
            if [ -d "$p" ]; then
                project_paths="$project_paths $p"
            else
                echo "[entrypoint] WARNING: KANBAN_PROJECTS path not found: $p"
            fi
        done
    else
        if [ -d "/projects" ]; then
            for dir in /projects/*/; do
                [ -d "$dir" ] && project_paths="$project_paths ${dir%/}"
            done
        fi
    fi

    local count=0
    for p in $project_paths; do
        if is_git_repo "$p"; then
            merge_into_workspace_index "$p"
            count=$((count + 1))
        else
            echo "[entrypoint] Skipping non-git directory: $p"
        fi
    done

    echo "[entrypoint] Project registration complete: $count repo(s) processed"
}

configure_claude_auth() {
    local api_key="${ANTHROPIC_API_KEY:-}"

    if [ -z "$api_key" ]; then
        echo "[entrypoint] No Claude auth configured (set ANTHROPIC_API_KEY)"
        return 0
    fi

    mkdir -p "$CLAUDE_SETTINGS_DIR"

    local existing_settings="{}"
    if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
        existing_settings=$(cat "$CLAUDE_SETTINGS_FILE")
    fi

    local env_block
    echo "[entrypoint] Configuring Claude Code with direct Anthropic API key"
    env_block=$(jq -n --arg ak "$api_key" '{ANTHROPIC_API_KEY: $ak}')

    echo "$existing_settings" | jq --argjson env "$env_block" '
        .env = (.env // {}) + $env
    ' > "$CLAUDE_SETTINGS_FILE.tmp" 2>/dev/null

    mv "$CLAUDE_SETTINGS_FILE.tmp" "$CLAUDE_SETTINGS_FILE"
    chown -R kanban:kanban "$CLAUDE_SETTINGS_DIR" 2>/dev/null || true
    echo "[entrypoint] Claude auth configured -> $CLAUDE_SETTINGS_FILE"
}

configure_default_agent() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo '{}' > "$CONFIG_FILE"
    fi

    local current_agent
    current_agent=$(jq -r '.selectedAgentId // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$current_agent" ] || [ "$current_agent" = "codex" ]; then
        if command -v claude >/dev/null 2>&1; then
            local config_json
            config_json=$(cat "$CONFIG_FILE")
            echo "$config_json" | jq '.selectedAgentId = "claude"' > "$CONFIG_FILE.tmp" 2>/dev/null
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            echo "[entrypoint] Set default agent to 'claude'"
        fi
    else
        echo "[entrypoint] Agent already configured: $current_agent"
    fi

    chown kanban:kanban "$CONFIG_FILE" 2>/dev/null || true
}

fix_permissions() {
    chown -R kanban:kanban /home/kanban/.cline /home/kanban/.claude 2>/dev/null || true
    echo "[entrypoint] Permissions fixed for /home/kanban/.cline and /home/kanban/.claude"
}

cleanup() {
    echo ""
    echo "[entrypoint] Shutting down..."
    if [ -n "$KANBAN_PID" ]; then
        kill -TERM "$KANBAN_PID" 2>/dev/null || true
        wait "$KANBAN_PID" 2>/dev/null || true
    fi
    nginx -s quit 2>/dev/null || true
    echo "[entrypoint] Done."
}

trap 'cleanup' SIGINT SIGTERM

setup_nginx
validate_nginx_conf
register_projects
configure_claude_auth
configure_default_agent
fix_permissions

echo "[entrypoint] Starting nginx on 0.0.0.0:3484"
nginx -g "daemon off;" &
NGINX_PID=$!

echo "[entrypoint] Starting kanban: $@"
"$@" &
KANBAN_PID=$!

wait -n "$NGINX_PID" "$KANBAN_PID" 2>/dev/null || true
cleanup
