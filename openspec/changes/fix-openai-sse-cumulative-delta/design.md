## Context

The `ClineTaskSessionService.onMessage` callback receives `ClineTaskMessage` objects whose `content` field is the full assistant message text accumulated so far. This is because the kanban UI replaces message content in-place (not appending), so cumulative content works correctly for the chat panel.

OpenAI's SSE streaming convention expects each `delta.content` to be **incremental** — only the new text since the previous chunk. Clients like Open WebUI append each delta to build the final response.

## Goals / Non-Goals

**Goals:**
- SSE chunks contain only incremental text (not full cumulative text)
- Works with Open WebUI and any OpenAI SDK client

**Non-Goals:**
- Changing the kanban internal message model (it stays cumulative)
- Changing `appendAssistantChunk` or `cline-session-state.ts`

## Decisions

### 1. Diff on the handler side

Track `previousContentLength` in the `onMessage` closure. On each message:

```typescript
let previousContentLength = 0;

const onMessage = (msgTaskId: string, message: ClineTaskMessage) => {
    if (msgTaskId !== taskId || finished) return;
    if (message.role === "assistant" && message.content) {
        const delta = message.content.slice(previousContentLength);
        previousContentLength = message.content.length;
        if (delta) {
            sentContent = true;
            res.write(createChatChunk(chatId, model, { content: delta }, null));
        }
    }
};
```

This is the canonical approach for bridging cumulative emitters to delta consumers. No changes to the kanban core.

### 2. No tool call exposure

Tool call messages (role != "assistant") are skipped as before. The assistant role filter already handles this.

### 3. First chunk: role announcement sent before any content

The existing `createChatChunk(chatId, model, { role: "assistant" }, null)` line is sent before entering the message loop — this stays unchanged. The first content delta comes after the role announcement.

## Risks / Trade-offs

- **Single-byte addition** vs **tracking previous length** — the diff approach is simple and correct. Tracking `previousContentLength` handles all cases (including truncated text, message resets).
- **Race condition**: If the kanban agent restarts or clears messages mid-stream, the `previousContentLength` could be wrong (content shrinks). The `finished` flag and `cleanup()` handle this — the stream ends and the client gets ` [DONE]`.
