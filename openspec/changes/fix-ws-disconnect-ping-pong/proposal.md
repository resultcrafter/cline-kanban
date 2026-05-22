## Why

The runtime state WebSocket (`/api/runtime/ws`) disconnects every ~2 minutes when deployed behind the Cloudflare Tunnel + nginx reverse proxy chain. The kanban web app shows "disconnected from cline" in the UI each time, then reconnects after a brief delay. This happens because there is **zero keepalive/heartbeat logic** anywhere in the WebSocket stack — neither server nor client sends ping/pong frames or application-level heartbeat messages. Idle connections are silently killed by intermediate proxies (CF tunnel or nginx) and only detected when the next message attempt fails.

Current behavior observed in nginx access logs:
```
12:04:54  WS connect → 101
12:06:00  (no traffic — idle ~66s)
12:06:00  connection dropped by proxy, client reconnects
12:06:00  WS connect → 101  (cycle repeats every ~2m06s)
```

The client does have exponential-backoff reconnection (`use-runtime-state-stream.ts:327-339`), so it recovers — but the constant connect/disconnect cycle causes:
- Visible "Disconnected" flicker in the UI every ~2 minutes
- Full state re-snapshot on every reconnect (~144KB per reconnect per client)
- Unnecessary load on the server rebuilding snapshots
- Potential data loss if a state update arrives during the reconnection gap

## What Changes

- Add WebSocket ping/pong keepalive to the **server-side** `RuntimeStateHub` using the `ws` library's built-in ping mechanism (`client.ping()` on a timer)
- Add **client-side** pong response handling and an application-level ping timeout detector that closes stale connections proactively
- Add a new `ping` message type to the runtime state stream protocol so the client can detect server liveness at the application level (in addition to WS-level ping frames, which are opaque to browser `WebSocket` API)

## Capabilities

### New Capabilities
- `ws-keepalive`: Server and client keepalive mechanism that prevents idle WebSocket connections from being terminated by reverse proxies

### Modified Capabilities
- `runtime-state-stream`: The existing runtime state WebSocket stream gains ping/pong messages and automatic connection health monitoring

## Impact

- `src/server/runtime-state-hub.ts` — add per-client ping timer on connection, clear on close
- `web-ui/src/runtime/use-runtime-state-stream.ts` — add pong listener and ping timeout detection
- `src/core/api-contract.ts` — add `ping` message type to the stream discriminated union
- `web-ui/src/runtime/types.ts` — add `ping` type to the client-side message union (if separately defined)
