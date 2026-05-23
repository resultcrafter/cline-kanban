## Context

The kanban server is a raw Node.js HTTP server (no Express/Fastify) using `createServer` with a single `requestHandler`. It uses tRPC v11 for its RPC API and `ws` for WebSocket state streaming. Project workspace resolution currently uses `x-kanban-workspace-id` header or `?workspaceId=` query param — never URL path segments. The URL path `/translator-copilot-service` is client-side SPA routing served as a static asset.

Each workspace gets its own `ClineTaskSessionService` instance (stored in `clineTaskSessionServiceByWorkspaceId` map in `runtime-server.ts`). Home agent sessions use a deterministic taskId: `__home_agent__:{workspaceId}:{agentId}`. Messages are persisted to `~/.cline/data/` by the Cline SDK (`ClineCore`). The `sendTaskSessionInput` method with `resumeFromPersistence: true` loads full history from disk if no in-memory session exists.

The existing `sendTaskChatMessage` flow in `runtime-api.ts` (lines 589-657) is the reference implementation for how to send a message to a home agent session — it calls `sendTaskSessionInput`, handles the null return (no active session) by starting with `resumeFromPersistence: true`, and returns the summary + latest message.

## Goals / Non-Goals

**Goals:**
- Expose `/{projectSlug}/v1/chat/completions` that any OpenAI SDK client can call
- Share conversation state with the kanban web UI — same taskId, same messages, same persistence
- Stream SSE responses in OpenAI format (`data: {"choices":[{"delta":{"content":"..."}}]}`)
- Simple bearer token auth from env var
- Minimal code — reuse existing `ClineTaskSessionService`, `loadWorkspaceContextById`, `createHomeAgentSessionId`
- Only `stream: true` supported

**Non-Goals:**
- Non-streaming mode (`stream: false`)
- Multi-turn conversation management via the `messages[]` array (we take the last user message only)
- Function calling / tool call passthrough (the agent handles tools internally)
- API key management UI or multi-user auth
- Agent selection via the API (uses global default)
- Embeddings, models listing, or other OpenAI endpoints

## Decisions

### 1. Route pattern: `/{projectSlug}/v1/chat/completions`

```
POST /translator-copilot-service/v1/chat/completions
POST /geo-audit-adk/v1/chat/completions
POST /buddy-session-service/v1/chat/completions
```

The `{projectSlug}` is the workspace ID (derived from the repo folder name by `toWorkspaceIdBase()` in `workspace-state.ts`). This matches the kanban UI URL pattern.

Route matching: in `runtime-server.ts`, before the static asset fallback (line ~411), check if the URL matches `/{segment}/v1/chat/completions` with method POST.

### 2. New file: `src/server/openai-compat-handler.ts`

A self-contained handler module that:
1. Validates auth (bearer token)
2. Parses the OpenAI request body (`messages[]`, `model`, `stream`)
3. Extracts projectSlug from URL path
4. Resolves workspace via `loadWorkspaceContextById(projectSlug)`
5. Gets scoped `ClineTaskSessionService`
6. Constructs `taskId = createHomeAgentSessionId(workspaceId, "cline")`
7. Extracts last user message from `messages[]`
8. Sends via `sendTaskSessionInput` or `startTaskSession` (same pattern as `runtime-api.ts` sendTaskChatMessage)
9. Subscribes to `service.onMessage(taskId, ...)` to collect assistant response chunks
10. Streams SSE in OpenAI format
11. Unsubscribes and cleans up on completion

This keeps the handler isolated — no changes to the existing tRPC API or WS hub.

### 3. Message flow — mirror `sendTaskChatMessage`

```
┌─────────────────────────────────────────────────────────────────┐
│  openai-compat-handler.ts                                       │
│                                                                  │
│  1. Parse body: { messages: [{role:"user", content:"fix bug"}] }│
│  2. Extract last user message text                               │
│  3. taskId = "__home_agent__:translator-copilot:cline"           │
│  4. result = service.sendTaskSessionInput(taskId, text)          │
│     ├─ returns summary → session active, message sent           │
│     └─ returns null → no active session                          │
│  5. If null:                                                     │
│     service.startTaskSession({                                   │
│       taskId, cwd: workspacePath, prompt: text,                  │
│       resumeFromPersistence: true                                │
│     })                                                           │
│  6. Subscribe to service.onMessage(taskId, handler)              │
│  7. Stream SSE:                                                  │
│     - assistant text → delta content chunks                      │
│     - tool call messages → skip (agent handles internally)       │
│     - session state change to idle → send [DONE]                 │
│  8. Unsubscribe                                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4. SSE response format

Standard OpenAI chat completions streaming format:

```
data: {"id":"chatcmpl-__home_agent__:translator-copilot:cline","object":"chat.completion.chunk","created":1716490000,"model":"cline","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-__home_agent__:translator-copilot:cline","object":"chat.completion.chunk","created":1716490000,"model":"cline","choices":[{"index":0,"delta":{"content":"I'll"},"finish_reason":null}]}

data: {"id":"chatcmpl-__home_agent__:translator-copilot:cline","object":"chat.completion.chunk","created":1716490000,"model":"cline","choices":[{"index":0,"delta":{"content":" fix"},"finish_reason":null}]}

data: {"id":"chatcmpl-__home_agent__:translator-copilot:cline","object":"chat.completion.chunk","created":1716490000,"model":"cline","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

### 5. Auth: `KANBAN_API_KEY` env var

```typescript
function validateAuth(request: IncomingMessage): boolean {
    const apiKey = process.env.KANBAN_API_KEY;
    if (!apiKey) return true; // No key configured = open access
    const authHeader = request.headers.authorization;
    if (!authHeader?.startsWith("Bearer ")) return false;
    return authHeader.slice(7) === apiKey;
}
```

If `KANBAN_API_KEY` is not set, the endpoint is open (same as current kanban passcode-less mode). If set, requests without a matching Bearer token get `401 Unauthorized`.

### 6. Detecting response completion

The `ClineTaskSessionService` emits summary updates when the session state changes. The session goes through states: `running` → `idle` | `awaiting_review` | `failed`. When the summary state transitions away from `running`, the response is complete.

Subscribe to both `onMessage` (for text chunks) and `onSummary` (for completion detection):

```
service.onSummary(summary => {
    if (summary.taskId !== taskId) return;
    if (summary.state === "idle" || summary.state === "awaiting_review" || summary.state === "failed") {
        // Response complete — send [DONE]
    }
});
service.onMessage((msgTaskId, message) => {
    if (msgTaskId !== taskId) return;
    if (message.role === "assistant" && message.content) {
        // Stream as SSE delta content
    }
});
```

### 7. Integration point in `runtime-server.ts`

In the `requestHandler` function, after tRPC handling and before static assets:

```typescript
// After: if (url.startsWith("/api/")) { ... return 404 }
// Before: static asset serving

// OpenAI-compatible endpoint
if (request.method === "POST" && openaiCompatRouteMatch(url)) {
    const { projectSlug } = openaiCompatRouteMatch(url);
    return handleOpenAiCompatRequest(request, response, projectSlug, deps);
}

// Static assets (SPA fallback)
```

The route match checks for pattern `/{slug}/v1/chat/completions`.

### 8. Error handling

| Case | HTTP Status | Body |
|------|-------------|------|
| Invalid JSON body | 400 | `{"error":{"message":"Invalid JSON","type":"invalid_request_error"}}` |
| `stream: false` | 400 | `{"error":{"message":"Only streaming is supported","type":"invalid_request_error"}}` |
| No `messages` array or empty | 400 | `{"error":{"message":"messages is required","type":"invalid_request_error"}}` |
| No user message in `messages` | 400 | `{"error":{"message":"At least one user message is required","type":"invalid_request_error"}}` |
| Missing/invalid auth | 401 | `{"error":{"message":"Unauthorized","type":"authentication_error"}}` |
| Unknown project slug | 404 | `{"error":{"message":"Project not found: {slug}","type":"not_found_error"}}` |
| Agent session busy | 429 | `{"error":{"message":"Agent is busy, try again later","type":"rate_limit_error"}}` |
| Internal error | 500 | `{"error":{"message":"Internal server error","type":"server_error"}}` |

Error response format matches OpenAI's error structure.

## Risks / Trade-offs

- **Single-turn only** — the API takes the last user message, ignoring conversation history in `messages[]`. The actual conversation continuity comes from the shared taskId + SDK persistence. This means an OpenAI client that sends full `messages[]` history will have that history ignored — only the latest user message is used. This is acceptable because the Cline agent maintains its own context.
- **No concurrent request handling per project** — if two API calls arrive for the same project simultaneously, the second gets a 429. The agent can only process one turn at a time.
- **`model` field ignored** — the agent uses the provider/model configured in the kanban settings, not what the client requests. The SSE response reports `model: "cline"` regardless.
- **Agent runs with tools** — the agent may execute file operations, run commands, etc. The API caller has no control over this. Tool call details are not exposed in the SSE stream — only the final text response.
- **No `usage` field** — token counts are not available from the Cline SDK event stream. The SSE chunks omit `usage`.
