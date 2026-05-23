## Why

The kanban app exposes a rich agent workspace via its web UI, but there's no programmatic API for external tools (like Open WebUI, custom scripts, or AI orchestrators) to interact with project agents. An OpenAI-compatible `/v1/chat/completions` endpoint would let any OpenAI SDK client chat with a project's home agent — using the same conversation, same agent, same message history as the kanban UI.

Key benefit: **shared conversation state**. A user can start chatting via Open WebUI, continue in the kanban web UI, and switch back — all seeing the same messages. This works because home agent sessions use a deterministic `taskId` (`__home_agent__:{workspaceId}:{agentId}`), messages are persisted to disk by the Cline SDK, and `resumeFromPersistence: true` loads full history on reconnect.

## What Changes

- Add an OpenAI-compatible HTTP endpoint at `/{projectSlug}/v1/chat/completions` that accepts the standard OpenAI chat completions request format and streams SSE responses
- Path-based project resolution: the URL segment before `/v1/` is the workspace ID (e.g., `/translator-copilot-service/v1/chat/completions`)
- Bearer token auth via `KANBAN_API_KEY` env var — if set, requests must include `Authorization: Bearer <value>`
- Streaming only (`stream: true`); `stream: false` returns an error
- Single-turn: takes the last `user` message from `messages[]` array, sends it to the existing `ClineTaskSessionService` — the same service used by the kanban web UI
- Reuses the global default agent (`cline`) configured in `config.json` — no agent selection in the API

## Capabilities

### New Capabilities
- `openai-compat-api`: HTTP endpoint that exposes the kanban's home agent sessions as an OpenAI-compatible chat completions API, with path-based project routing and SSE streaming

### Modified Capabilities
- `runtime-server`: Add route handling for `/{projectSlug}/v1/chat/completions` in the HTTP request handler, before the static asset fallback

## Impact

- New file: `src/server/openai-compat-handler.ts` — request parsing, project resolution, session management, SSE streaming, OpenAI response format mapping
- Modified: `src/server/runtime-server.ts` — add route for `/{projectSlug}/v1/chat/completions` pattern before the SPA fallback
- Modified: `docker/entrypoint.sh` — (optional) add `KANBAN_API_KEY` to supported env vars
- Deployment: add `KANBAN_API_KEY` to `.kanban/.env` or `-e` flag
