## 1. Modify `openai-compat-handler.ts`

- [x] 1.1 Add `handleOpenAiModelsRequest()` — read workspace index via `listWorkspaceIndexEntries()`, return all entries as OpenAI model objects in `{ object: "list", data: [...] }` format
- [x] 1.2 Remove `matchOpenAiCompatRoute()` function (no longer needed)
- [x] 1.3 Modify `handleOpenAiCompatRequest()` — extract project slug from parsed `body.model` field instead of `projectSlug` parameter; add validation for missing model field
- [x] 1.4 Update function signature: `handleOpenAiCompatRequest(req, res, deps)` — remove `projectSlug` param, get it from body instead

## 2. Modify `runtime-server.ts`

- [x] 2.1 Remove `matchOpenAiCompatRoute` import and the path-based route block
- [x] 2.2 Add `GET /v1/models` route — exact match on pathname, delegates to `handleOpenAiModelsRequest`
- [x] 2.3 Modify `POST /v1/chat/completions` route — exact match on pathname, delegates to `handleOpenAiCompatRequest` (no projectSlug param)

## 3. Modify `nginx.conf.template`

- [x] 3.1 Replace the `~ ^/[a-z0-9][a-z0-9-]*/v1/` location block with a simple `location /v1/` block with SSE-optimized settings (proxy_buffering off, CORS)

## 4. Verify

- [x] 4.1 Commit, push, verify CI builds
- [x] 4.2 Pull new image, redeploy container
- [x] 4.3 Test `GET /v1/models` — verify all projects appear as models
- [x] 4.4 Test `POST /v1/chat/completions` with `model: "translator-copilot-service"` — verify SSE streaming works
- [x] 4.5 Test through nginx on port 3484
- [x] 4.6 Test error cases: missing model (400), unknown model (404), invalid auth (401)
- [ ] 4.7 Configure Open WebUI to use `http://127.0.0.1:3485/v1` as base URL — verify projects appear as models
