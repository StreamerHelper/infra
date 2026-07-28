# Douyin Resolver

`douyin-resolver` is a small internal HTTP service that resolves Douyin live
status and stream URLs without depending on an account login Cookie.

It delegates the evolving Douyin request/signature implementation to a pinned
[Biliup](https://github.com/biliup/biliup) revision and keeps that dependency
outside the TypeScript backend. The resolver is intentionally narrow: it does
not record, persist credentials, expose a browser, or accept arbitrary URLs.

## API

### `GET /healthz`

Returns the resolver version and the exact Biliup commit compiled into the
binary. It does not call Douyin.

### `POST /v1/douyin/resolve`

```json
{
  "url": "https://live.douyin.com/123456789",
  "quality": "high",
  "protocol": "flv"
}
```

- `quality`: `high`, `medium`, or `low`; defaults to `high`.
- `protocol`: `flv` or `hls`; defaults to `flv`.
- Unknown fields, non-HTTPS URLs, non-Douyin hosts, credentials in URLs, custom
  ports, fragments, and unsupported Douyin paths are rejected.

Live response:

```json
{
  "state": "live",
  "roomId": "742000000000",
  "title": "Live title",
  "stream": {
    "url": "https://pull.example/live.flv?...",
    "headers": {
      "cookie": "ttwid=...",
      "referer": "https://live.douyin.com/",
      "user-agent": "Mozilla/5.0 ..."
    },
    "effectiveQuality": "high"
  }
}
```

Offline response:

```json
{
  "state": "offline",
  "roomId": "123456789"
}
```

Transient failure response:

```json
{
  "state": "unavailable",
  "code": "UPSTREAM_TIMEOUT",
  "message": "Douyin upstream request timed out; retry later"
}
```

`offline` and `unavailable` are deliberately different. A caller must never
treat an upstream timeout, rate limit, or resolver overload as proof that a
stream ended.

## Security boundary

This service must only be reachable on the private application network.
`live.stream.headers` may contain a dynamically acquired anonymous `ttwid`
Cookie. The service keeps that value in memory, returns it only to its internal
caller, and never writes request or response bodies, stream URLs, headers, or
Cookies to logs.

The input allowlist also prevents using the resolver as a general-purpose
server-side request proxy.

## Reliability behavior

- Biliup's anonymous chain supplies dynamic `ttwid`, `odin_ttid`,
  `__ac_nonce`, `msToken`, and `a_bogus` values.
- Biliup first uses the Douyin Web room-enter API and falls back to the H5
  reflow API when room data is unavailable.
- One long-lived Biliup resolver instance shares its process-level `ttwid`.
- A failed request rotates that instance and retries once, so an invalidated
  guest identity does not survive forever.
- A global concurrency gate prevents polling bursts from flooding Douyin.
- Live results are cached for 3 seconds and offline results for 5 seconds,
  coalescing StreamerHelper's status and stream-resolution calls.
- An outer timeout bounds the full Web/H5/retry chain.

## Configuration

| Environment variable | Default | Range |
| --- | --- | --- |
| `DOUYIN_RESOLVER_BIND` | `127.0.0.1:7100` | Valid socket address |
| `DOUYIN_RESOLVER_TIMEOUT_MS` | `20000` | `1000`–`60000` |
| `DOUYIN_RESOLVER_MAX_CONCURRENCY` | `8` | `1`–`32` |
| `DOUYIN_RESOLVER_HEALTH_URL` | `http://127.0.0.1:7100/healthz` | Healthcheck mode only |

## Local development

```bash
cargo test --locked
cargo run --locked
```

```bash
curl -sS http://127.0.0.1:7100/v1/douyin/resolve \
  -H 'Content-Type: application/json' \
  --data '{"url":"https://live.douyin.com/123456789","quality":"high","protocol":"flv"}'
```

## Container

```bash
docker build -t streamerhelper/douyin-resolver .
docker run --rm -p 127.0.0.1:7100:7100 streamerhelper/douyin-resolver
```

The runtime runs as UID/GID `10001`, contains no shell-based healthcheck
dependency, and needs only outbound HTTPS access plus an internal connection
from the StreamerHelper backend.

The Biliup source revision is pinned in both `Cargo.toml` and `Cargo.lock`.
Review upstream Douyin changes and rerun contract/live tests before changing
that revision.
