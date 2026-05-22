## 1. Add `ping` message type to API contract

- [x] 1.1 Add `runtimeStateStreamPingMessageSchema` to `src/core/api-contract.ts` — a simple `z.object({ type: z.literal("ping") })` schema
- [x] 1.2 Add `RuntimeStateStreamPingMessage` type alias
- [x] 1.3 Add the ping schema to the `runtimeStateStreamMessageSchema` discriminated union array
- [x] 1.4 Add `"ping"` to the corresponding client-side type union in `web-ui/src/runtime/types.ts` (if types are mirrored there rather than imported from the contract) — no-op, types imported directly from api-contract

## 2. Server-side keepalive in RuntimeStateHub

- [x] 2.1 Add a `pingIntervalMs = 30_000` constant near `TASK_SESSION_STREAM_BATCH_MS` in `src/server/runtime-state-hub.ts`
- [x] 2.2 Create a `pingTimersByClient` map (`Map<WebSocket, NodeJS.Timeout>`) to track per-client ping timers
- [x] 2.3 In the `runtimeStateWebSocketServer.on("connection", ...)` handler, after initial snapshot delivery succeeds, start a `setInterval` that calls `client.ping()` and `sendRuntimeStateMessage(client, { type: "ping" })` every 30s
- [x] 2.4 In `cleanupRuntimeStateClient()`, clear the ping timer from `pingTimersByClient` and delete the entry
- [x] 2.5 In `RuntimeStateHub.close()`, clear all remaining ping timers before terminating clients

## 3. Client-side liveness timeout in useRuntimeStateStream

- [x] 3.1 Add `PING_TIMEOUT_MS = 90_000` constant in `web-ui/src/runtime/use-runtime-state-stream.ts`
- [x] 3.2 In the `connect()` function, initialize a `livenessTimer` variable
- [x] 3.3 In `socket.onopen`, start a `setTimeout` that closes the socket if no message is received within 90s
- [x] 3.4 In `socket.onmessage`, reset the liveness timer (clear + set new timeout) on every received message — this covers both data messages and `ping` messages
- [x] 3.5 In `cleanupSocket()`, clear the liveness timer
- [x] 3.6 Handle the `ping` message type in the `onmessage` handler — no dispatch needed, just let it reset the liveness timer (the existing fall-through behavior will naturally ignore it)

## 4. Verify and test

- [x] 4.1 Run the TypeScript build to verify no type errors: `npm run build` or equivalent
- [ ] 4.2 Run existing tests: `npm test` or the project's test command — blocked: requires Node >= 20, current is v18
- [ ] 4.3 Start the dev server and connect via browser — verify no "disconnected" flicker over a 10-minute window
- [ ] 4.4 Check server logs for ping messages being sent (no errors on ping send)
- [ ] 4.5 Test connection recovery: temporarily block network, verify client detects dead connection within 90s and reconnects
