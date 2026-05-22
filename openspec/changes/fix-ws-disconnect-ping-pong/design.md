## Context

The kanban app runs behind a Cloudflare Tunnel → nginx → Node.js stack. The runtime state WebSocket at `/api/runtime/ws` is a pure server-push stream (client never sends messages). The `ws` library v8.18.0 is used server-side. Browser `WebSocket` API is used client-side.

Key constraint: **browser `WebSocket` API does not expose WS-level ping/pong frames to JavaScript**. The browser automatically responds to ping frames with pong, but there is no `onping`/`onpong` event. This means we need an **application-level ping message** for the client to detect server liveness.

The nginx config already has `proxy_read_timeout 86400s` — so nginx is not the problem. The disconnect is caused by the Cloudflare Tunnel's idle timeout (typically ~100s).

## Goals / Non-Goals

**Goals:**
- Prevent idle WebSocket connections from being killed by the CF Tunnel
- Client detects server liveness within a bounded time window
- Minimal changes to the existing message protocol
- Clean connection lifecycle (timers properly cleaned up on close/shutdown)

**Non-Goals:**
- Changing the nginx or cloudflared configuration (that's a separate infrastructure change)
- Adding keepalive to terminal WebSockets (different concern, lower priority since terminal sessions are typically active)
- Adding reconnection for terminal WebSockets (out of scope)
- Changing the exponential backoff reconnect strategy

## Decisions

### 1. Two-layer keepalive: WS-level ping + application-level `ping` message

**WS-level ping (server → proxy → server):** The `ws` library supports `client.ping()` which sends a WebSocket protocol-level ping frame. Nginx and CF Tunnel will forward this frame and receive the automatic pong response, keeping the TCP connection alive through the proxy chain. This prevents the proxy from dropping idle connections.

**Application-level `ping` message (server → client):** Since browser `WebSocket` cannot observe WS-level ping/pong, the server also sends a JSON message `{ "type": "ping" }` every interval. The client uses this to detect that the server is alive. If the client doesn't receive any message (data or ping) within a timeout window, it proactively closes and reconnects.

This two-layer approach means:
- The proxy sees traffic (WS ping/pong) and keeps the connection open
- The client has visibility into server health via application pings

### 2. 30-second ping interval

Send both WS-level ping and application-level `ping` message every **30 seconds**. This is well within the CF Tunnel's ~100s idle timeout, provides fast detection of dead connections, and adds negligible overhead (one small JSON message per 30s per connected client).

### 3. 90-second client-side liveness timeout

If the client receives **no message at all** (neither data nor ping) for 90 seconds, it considers the connection dead and proactively closes + reconnects. This is 3x the ping interval, providing tolerance for occasional latency spikes.

### 4. Timer cleanup tied to client lifecycle

All per-client timers (server ping interval, client liveness timeout) are registered in cleanup maps and cleared on `close` events and during `RuntimeStateHub.close()` shutdown.

## Risks / Trade-offs

- **Application-level ping adds a message type to the discriminated union** — this requires updating `api-contract.ts` and all places that switch on `type`. The `ping` message is trivial (`{ type: "ping" }`) and client handlers that use `switch`/`if-else` chains will simply ignore it (fall through to no-op).
- **Timer memory leaks** — if timers aren't cleaned up on client disconnect, they'll accumulate. Mitigation: central timer cleanup in the `close` handler, same pattern used for existing `taskSessionBroadcastTimersByWorkspaceId`.
- **Browser auto-pong** — the browser will automatically respond to WS-level pings, so the server doesn't need to wait for explicit pong handling. But the server could optionally track pong responses to detect dead clients on its side. For now, we skip server-side pong tracking to keep the change minimal.
