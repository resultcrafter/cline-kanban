## Why

The OpenAI-compatible SSE endpoint sends each assistant message chunk as a standalone `delta.content`. However, the kanban's `ClineTaskSessionService.onMessage()` emits the **full cumulative** assistant text on every chunk (e.g., `"Hello"` → `"Hello! How"` → `"Hello! How can"`). The handler treats each as a delta, causing Open WebUI to display concatenated duplicates:

```
HelloHello! HowHello! How canHello! How can I...   ← bug
```

The fix: track the previous message content length and only send the new portion (the delta), matching OpenAI's SSE convention:

```
Hello! How can I...   ← correct (incremental deltas)
```

## What Changes

- Modify `handleOpenAiCompatRequest()` in `openai-compat-handler.ts` to track previous assistant message content length and `slice()` the delta from cumulative content

## Capabilities

### Modified Capabilities
- `openai-compat-api`: SSE streaming now sends incremental text deltas instead of cumulative content

## Impact

- Modified: `src/server/openai-compat-handler.ts` — add `previousContentLength` tracking in the `onMessage` handler
