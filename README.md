# kwwk-agy-relay

A self-hosted drop-in replacement for AirRelay, the relay
[yellowplushq/kwwk](https://github.com/yellowplushq/kwwk)'s `agy` provider talks to.
It serves the [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli)
(`agy`) as an Anthropic Messages endpoint, so kwwk can use `agy` models without
running `agy` itself. kwwk needs no changes: it already speaks this wire to AirRelay.

> Status: early scaffold. The HTTP server runs; the ACP bridge is being built.

## How it works

```
kwwk ──POST /v1/messages (SSE)──▶ kwwk-agy-relay ──ACP JSON-RPC (stdio)──▶ agy acp ──▶ Google
      Authorization: Bearer <Google access token>      │
      x-relay-secret: <shared secret>                  └── loopback MCP server ◀── agy calls client tools
```

- **Wire**: Anthropic Messages in (`POST /v1/messages`, streaming SSE), model ids
  `agy/<slug>`; `GET /v1/agy/models` lists what `agy` offers.
- **Sessions**: Messages requests are stateless; ACP sessions are not. A request
  that extends a session's transcript sends only the new input, anything else
  opens a fresh session seeded with a replay of the history.
- **Client tools**: the request's `tools` are exposed to `agy` through a loopback
  MCP server. When `agy` calls one, the relay ends the HTTP response with a
  `tool_use` block and holds the MCP call open; the next request's `tool_result`
  completes it and the same ACP turn streams on.
- **Credentials**: each request carries the user's Google OAuth access token
  (kwwk's `agy` login). The relay runs one `agy` per user with its own
  `--app-data-dir`, where `agy` keeps file-based credentials on hosts without a
  desktop keyring.
- **Built-in agy tools** are refused at `agy`'s permission prompt, and every
  session runs in an empty placeholder workspace.

## Run

```sh
swift build -c release
RELAY_SECRET=… .build/release/kwwk-agy-relay --host 0.0.0.0 --port 8787 --agy ~/.local/bin/agy
```

| Variable / flag | Meaning |
|---|---|
| `RELAY_SECRET` | Shared secret required in `x-relay-secret` (unset: no check, dev only) |
| `--host` / `RELAY_HOST` | Bind address (default `127.0.0.1`) |
| `--port` / `RELAY_PORT` | Port (default `8787`) |
| `--agy` / `AGY_PATH` | `agy` executable |
| `--data-root` / `RELAY_DATA_ROOT` | Per-user `agy` state |

Point kwwk at it by storing the relay URL as the `agy` login's `baseUrl`.

## Caveats

`agy` signs in with Antigravity's own OAuth client. Serving it to other people may
conflict with Google's Antigravity terms; this is meant for running your own
account through your own host.

## License

MIT
