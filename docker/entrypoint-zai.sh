#!/bin/bash
set -e

CLAUDE_JSON="/home/kanban/.claude.json"

configure_zai_mcp() {
    local api_key="${Z_AI_API_KEY:-}"

    if [ -z "$api_key" ]; then
        echo "[entrypoint-zai] Z_AI_API_KEY not set, skipping ZAI MCP setup"
        return 0
    fi

    echo "[entrypoint-zai] Configuring ZAI MCP servers (Z_AI_API_KEY present)"

    local existing_json="{}"
    if [ -f "$CLAUDE_JSON" ]; then
        existing_json=$(cat "$CLAUDE_JSON")
    fi

    local mcp_block
    mcp_block=$(jq -n \
        --arg ak "$api_key" \
        '{
            "zai-mcp-server": {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@z_ai/mcp-server"],
                "env": {
                    "Z_AI_API_KEY": $ak,
                    "Z_AI_MODE": "ZAI"
                }
            },
            "web-search-prime": {
                "type": "streamableHttp",
                "url": "https://api.z.ai/api/mcp/web_search_prime/mcp",
                "headers": {
                    "Authorization": ("Bearer " + $ak)
                }
            },
            "web-reader": {
                "type": "streamableHttp",
                "url": "https://api.z.ai/api/mcp/web_reader/mcp",
                "headers": {
                    "Authorization": ("Bearer " + $ak)
                }
            },
            "zread": {
                "type": "streamableHttp",
                "url": "https://api.z.ai/api/mcp/zread/mcp",
                "headers": {
                    "Authorization": ("Bearer " + $ak)
                }
            }
        }')

    echo "$existing_json" | jq --argjson mcp "$mcp_block" '
        .mcpServers = (.mcpServers // {}) + $mcp
    ' > "$CLAUDE_JSON.tmp" 2>/dev/null

    mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
    chown kanban:kanban "$CLAUDE_JSON" 2>/dev/null || true

    echo "[entrypoint-zai] ZAI MCP servers configured -> $CLAUDE_JSON"
}

configure_zai_mcp
fix_permissions

echo "[entrypoint-zai] Delegating to base entrypoint: $@"
exec /entrypoint.sh "$@"
