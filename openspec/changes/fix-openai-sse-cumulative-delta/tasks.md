## 1. Fix SSE delta vs cumulative content

- [x] 1.1 Add `previousContentLength` tracking variable in `handleOpenAiCompatRequest()` SSE streaming closure
- [x] 1.2 Modify `onMessage` handler to `slice(previousContentLength)` to extract delta, then update `previousContentLength`

## 2. Verify

- [x] 2.1 Commit, push, verify CI builds
- [x] 2.2 Pull new image, redeploy container
- [x] 2.3 Test via curl: `POST /v1/chat/completions` with `model: "geo-audit-adk"` — verify chunks are incremental (no cumulative prefix repetition)
- [ ] 2.4 Test via Open WebUI — send "hi" and verify response renders cleanly without "HelloHello! HowHello! How can" repetition
