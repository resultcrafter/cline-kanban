## Why

The initial OpenAI-compatible API implementation uses path-based routing (`/{projectSlug}/v1/chat/completions`), which is non-standard. Open WebUI and other OpenAI SDK clients expect the standard pattern:

1. `GET /v1/models` — list available models
2. `POST /v1/chat/completions` — send a chat request with `model` field selecting which model to use

By mapping each kanban project to a "model", the user selects a project by choosing a model in Open WebUI. This is the natural OpenAI convention — no custom URL patterns needed.

## What Changes

- Add `GET /v1/models` endpoint that returns all kanban workspace projects as model entries
- Move project routing from URL path to `body.model` field in `POST /v1/chat/completions`
- Remove the path-based `/{projectSlug}/v1/chat/completions` route (replaced by model-based routing)
- Remove the nginx SSE location block for `/{slug}/v1/` (no longer needed — all traffic goes through standard `/v1/` routes)
- Add a new nginx location block for `/v1/` with SSE-optimized settings

## Capabilities

### Modified Capabilities
- `openai-compat-api`: Simplified to standard `/v1/models` + `/v1/chat/completions` endpoints with model-based project routing

## Impact

- Modified: `src/server/openai-compat-handler.ts` — add models handler, change project routing from URL path to body.model
- Modified: `src/server/runtime-server.ts` — add `/v1/models` and `/v1/chat/completions` routes, remove path-based route
- Modified: `docker/nginx.conf.template` — replace `/{slug}/v1/` location block with `/v1/` location block
