## 1. Create `openai-compat-handler.ts`

- [x] 1.1 Create `src/server/openai-compat-handler.ts` with route pattern matcher: extract projectSlug from URLs matching `/{slug}/v1/chat/completions`
- [x] 1.2 Add auth validation function — read `KANBAN_API_KEY` from env, validate `Authorization: Bearer` header, return 401 on mismatch
- [x] 1.3 Add request body parser — parse JSON, validate `messages` array exists and has at least one user message, extract last user message text, reject `stream: false`
- [x] 1.4 Add project resolution — call `loadWorkspaceContextById(projectSlug)`, return 404 if not found
- [x] 1.5 Add session resolution — get scoped `ClineTaskSessionService`, construct `taskId = createHomeAgentSessionId(workspaceId, "cline")`
- [x] 1.6 Add message dispatch — call `service.sendTaskSessionInput(taskId, text)`, if null then call `service.startTaskSession({ taskId, cwd, prompt: text, resumeFromPersistence: true })` with provider config resolved via `clineProviderService.resolveLaunchConfig()`
- [x] 1.7 Add SSE streaming — set headers (`Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`), subscribe to `service.onMessage` and `service.onSummary`, stream assistant text as OpenAI delta chunks, detect completion via summary state change, send `[DONE]`
- [x] 1.8 Add error handling — catch all error paths, return OpenAI-format error JSON with appropriate HTTP status codes
- [x] 1.9 Add OpenAI-format response helpers — `createChatChunk(id, delta, finishReason)`, `createErrorResponse(message, type, status)` functions

## 2. Integrate into `runtime-server.ts`

- [x] 2.1 Import `openai-compat-handler.ts` and add route check in `requestHandler` — after tRPC/404 block, before static asset fallback, match `POST /{slug}/v1/chat/completions`
- [x] 2.2 Pass required dependencies to the handler: `loadWorkspaceContextById`, `getScopedClineTaskSessionService`, `clineProviderService`

## 3. Nginx configuration

- [x] 3.1 Update `docker/nginx.conf.template` — ensure `/{slug}/v1/chat/completions` paths are proxied to kanban (should work with existing `/` location block, but verify no auth or buffering interferes with SSE streaming)
- [x] 3.2 Add `proxy_buffering off` and `X-Accel-Buffering: no` headers for SSE paths if needed

## 4. Verify

- [ ] 4.1 Commit, push, verify CI builds
- [ ] 4.2 Pull new image, redeploy container with `KANBAN_API_KEY` env var
- [ ] 4.3 Test with curl: `curl -X POST https://cline.resultcrafter.com/translator-copilot-service/v1/chat/completions -H "Authorization: Bearer <key>" -H "Content-Type: application/json" -d '{"model":"cline","messages":[{"role":"user","content":"hello"}],"stream":true}'`
- [ ] 4.4 Verify conversation appears in kanban web UI for that project
- [ ] 4.5 Send a follow-up message via kanban UI, then send another via the API — verify both show in both interfaces
- [ ] 4.6 Test error cases: invalid auth (401), unknown project (404), stream:false (400), empty messages (400)
