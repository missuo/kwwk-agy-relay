# kwwk-agy-relay

A self-hosted drop-in replacement for AirRelay, the relay
[yellowplushq/kwwk](https://github.com/yellowplushq/kwwk)'s `agy` provider talks to.
It serves the [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli)
(`agy`) as an Anthropic Messages endpoint, so kwwk can use `agy` models without
running `agy` itself. kwwk needs no changes: it already speaks this wire to AirRelay.

## How it works

```
kwwk ──POST /v1/messages (SSE)──▶ kwwk-agy-relay ──ACP JSON-RPC (stdio)──▶ agy acp ──▶ Google
      Authorization: Bearer <Google access token>      │
                                                       └── loopback MCP server ◀── agy calls client tools
```

- **Wire**: Anthropic Messages in (`POST /v1/messages`, streaming SSE or not),
  model ids `agy/<slug>`; `GET /v1/agy/models` lists what `agy` offers.
- **Identity**: the bearer token is the caller's Google OAuth access token from
  kwwk's `agy` login. The relay checks it with Google's tokeninfo endpoint, accepts
  only tokens issued to the Antigravity CLI's OAuth client, and keys the caller by
  the account email.
- **One `agy` per user**: each user gets a private `HOME` where the relay writes
  their access token in `agy`'s own file credential format
  (`~/.gemini/antigravity-cli/antigravity-oauth-token`, no refresh token), and one
  `agy acp --process-per-session`. Every session runs in a worker that reads the
  credential when it starts, so a rotated token takes effect for the next session;
  idle sessions opened under the old token are closed when it rotates.
- **Sessions**: Messages requests are stateless; ACP sessions are not. A request
  whose transcript extends a session's (matched by text and tool-use ids, ignoring
  thinking) sends only the new input; anything else opens a fresh session seeded
  with a replay of the history.
- **Client tools**: the request's `tools` reach `agy` through a loopback MCP server.
  When `agy` calls one, the relay ends the HTTP response with a `tool_use` block and
  parks the MCP call; the next request's `tool_result` un-parks it and the same ACP
  turn streams on into the new response. Parked calls answer as SSE with progress
  notifications, so `agy` does not time out while the client runs the tool; after
  15 minutes without a result the session is dropped.
- **Built-in agy tools** are refused at `agy`'s permission prompt, and every session
  runs in an empty placeholder workspace.

## Build

macOS (development):

```sh
swift build
swift test                      # RELAY_LIVE=1 also runs a round trip against your local agy
```

A static Linux binary (x86_64 or aarch64, musl) from a Mac or Linux host needs an
open-source Swift toolchain and the matching static Linux SDK:

```sh
Scripts/build-linux-static.sh x86_64     # → dist/kwwk-agy-relay-linux-x86_64
```

## Run

Install `agy` for the account the relay runs as (`curl -fsSL
https://antigravity.google/cli/install.sh | bash`); no `agy` login is needed on the
host. Then:

```sh
RELAY_ALLOWED_USERS=me@example.com \
  kwwk-agy-relay --host 127.0.0.1 --port 8787 --agy ~/.local/bin/agy --data-root /var/lib/kwwk-agy-relay
```

| Variable / flag | Meaning |
|---|---|
| `RELAY_ALLOWED_USERS` | Comma-separated emails and/or `@domain`s allowed to use the relay. **Set it**: unset lets any Google account `agy` accepts run on your host |
| `RELAY_SECRET` | Optional shared secret required in `x-relay-secret`. kwwk clients never send it, so only set it when a gateway in front of the relay adds it |
| `--host` / `RELAY_HOST` | Bind address (default `127.0.0.1`; put TLS in front for remote use) |
| `--port` / `RELAY_PORT` | Port (default `8787`) |
| `--agy` / `AGY_PATH` | `agy` executable |
| `--data-root` / `RELAY_DATA_ROOT` | Per-user `agy` homes and workspaces (mode 0700, holds access tokens) |
| `--system-login` | Development: ignore tokens and use this machine's own signed-in `agy` |
| `RELAY_TOOL_TIMEOUT` | Seconds a parked tool call waits for the client's `tool_result` before the session is dropped (default 900) |
| `RELAY_MAX_SESSIONS` | Live sessions per user (default 4). Each holds an `agy` worker (~250 MB); the least recently used idle one is closed to make room and its conversation replays on its next turn |
| `RELAY_SESSION_IDLE` | Seconds before an idle session is closed (default 600) |
| `RELAY_USER_IDLE` | Seconds before a user's `agy` with no sessions is stopped (default 1800) |
| `RELAY_LOG=0` | Silence the one-line-per-session log on stderr (users appear as hashes) |

`deploy/kwwk-agy-relay.service` is an example systemd unit.

Point kwwk at the relay by storing its URL as the `agy` login's `baseUrl`. On a Mac
that has `agy` itself, kwwk talks to the local `agy` instead; set
`KWWK_AGY_LOCAL=0` to use the relay.

## Caveats

`agy` signs in with Antigravity's own OAuth client. Serving it to other people may
conflict with Google's Antigravity terms; this is meant for running your own
account through your own host.

## License

MIT
