## Context

The existing `openai-compat-handler.ts` uses path-based routing: `/{projectSlug}/v1/chat/completions`. The `matchOpenAiCompatRoute()` function extracts the project slug from the URL via regex `^/([a-z0-9][a-z0-9-]*)/v1/chat/completions$`. In `runtime-server.ts`, this route is checked after the `/api/` 404 block and before static assets.

The workspace index (`~/.cline/kanban/workspaces/index.json`) contains all registered projects with their workspaceId and repoPath. The `readWorkspaceIndex()` function in `workspace-state.ts` reads this file.

Open WebUI configures `OPENAI_API_BASE_URL` (e.g., `http://127.0.0.1:3485/v1`) and calls `GET {base_url}/models` to list available models, then `POST {base_url}/chat/completions` with `model` field to select which model to use.

## Goals / Non-Goals

**Goals:**
- Standard OpenAI API pattern: `GET /v1/models` + `POST /v1/chat/completions`
- Each kanban project appears as a model in the models list
- `body.model` field selects the project (replaces URL path routing)
- Works with Open WebUI out of the box

**Non-Goals:**
- Keeping the old `/{projectSlug}/v1/chat/completions` route (remove it entirely)
- Model metadata beyond what OpenAI returns (capabilities, pricing, etc.)
- Per-project model endpoint (`GET /v1/models/{project}`)

## Decisions

### 1. `GET /v1/models` — Read workspace index

```
GET /v1/models
Authorization: Bearer <KANBAN_API_KEY>

Response:
{
  "object": "list",
  "data": [
    {
      "id": "aimanager-telegram-webhook",
      "object": "model",
      "created": 1779570201,
      "owned_by": "kanban"
    },
    {
      "id": "translator-copilot-service",
      "object": "model",
      "created": 1779570201,
      "owned_by": "kanban"
    }
  ]
}
```

Read workspace index via `readWorkspaceIndex()` from `workspace-state.ts`. Map each entry's `workspaceId` to a model object. The `id` is the workspace ID (same as project slug).

### 2. `POST /v1/chat/completions` — Extract project from `body.model`

```
POST /v1/chat/completions
Authorization: Bearer <KANBAN_API_KEY>

{
  "model": "translator-copilot-service",
  "messages": [{"role": "user", "content": "hello"}],
  "stream": true
}
```

The `model` field is extracted from the parsed request body. It is used as the project slug for `loadWorkspaceContextById()`. If the model is missing or not a valid project, return appropriate errors.

### 3. Remove path-based route

Remove `matchOpenAiCompatRoute()` and the `/{slug}/v1/chat/completions` route from `runtime-server.ts`. Replace with simpler `/v1/models` and `/v1/chat/completions` routes.

### 4. Nginx: single `/v1/` location block

Replace the `/{slug}/v1/` regex location with a simple prefix match on `/v1/`:

```nginx
location /v1/ {
    proxy_pass http://127.0.0.1:3485;
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header X-Accel-Buffering no;
    # CORS headers (same as existing)
}
```

### 5. Error handling additions

| Case | HTTP Status | Body |
|------|-------------|------|
| Missing `model` field | 400 | `{"error":{"message":"model is required","type":"invalid_request_error"}}` |
| Unknown model/project | 404 | `{"error":{"message":"Model not found: {model}","type":"not_found_error"}}` |

### 6. Route matching in `runtime-server.ts`

Before static asset fallback, check for `/v1/` prefix:

```typescript
if (pathname === "/v1/models" && req.method === "GET") {
    await handleOpenAiModelsRequest(req, res, deps);
    return;
}
if (pathname === "/v1/chat/completions" && req.method === "POST") {
    await handleOpenAiCompatRequest(req, res, deps);
    return;
}
```

No regex needed — exact path matches.

## Risks / Trade-offs

- **Breaking change for path-based route users** — if anyone was using `/{projectSlug}/v1/chat/completions`, it stops working. Acceptable since this was just implemented and not yet distributed.
- **Model ID = project slug** — if a project slug collides with a real model name (e.g., "gpt-4"), it would shadow it. But since this is a standalone API endpoint, there's no conflict — it only serves kanban projects.
