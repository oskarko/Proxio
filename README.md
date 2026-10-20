# Proxio

Free, open-source (MIT) native macOS HTTP/HTTPS debugging proxy. Inspect, filter and export the traffic of your apps.

Status: early. Working today: plain HTTP forwarding with capture, HTTPS interception (own root CA, per-host leaf certificates, TLS terminated and re-originated), opaque CONNECT tunnelling when no CA is given, flow store with search, HAR export.

```
swift test
swift run proxio-cli 9090   # then point a client at 127.0.0.1:9090
curl -x http://127.0.0.1:9090 http://example.com/

# HTTPS interception: creates ~/Library/Application Support/Proxio/ca.pem on first run
swift run proxio-cli 9090 --mitm
curl -x http://127.0.0.1:9090 --cacert "$HOME/Library/Application Support/Proxio/ca.pem" https://example.com/
```

The root CA is never installed or trusted automatically. Clients only accept intercepted TLS if you explicitly trust `ca.pem`. The CA private key is stored in your login keychain (service `dev.proxio.ca`), not on disk; only the public `ca.pem` is a file. Anyone who can read the key can impersonate sites to a device that trusts the CA. Older installs with a plaintext `ca-key.pem` keep working and are only migrated after you confirm (`proxio-cli ca migrate`, or the prompt in the app); the file is then overwritten and deleted.

Proxio is an independent clean-room project. It is not affiliated with any commercial proxy tool and contains no code or assets from one.

## App

`scripts/bundle.sh` builds `build/Proxio.app` (ad-hoc signed). The window has three panels: domains, flow list, inspector. The CA and system proxy are only changed after you confirm the exact command in a dialog.

### Rewrite and replay

- **Breakpoints**: pause matching requests and/or responses, edit method, URL, headers, status and body, then execute or cancel (cancelled traffic answers 499). Response breakpoints ask the server for an uncompressed body so it stays editable.
- **Map Local**: answer matching requests from a file (read on every hit) or inline text, with status and headers; "Map Local with This Response" in the flow menu pre-fills it from a capture.
- **Map Remote**: send matching requests to another scheme, host, port or path.
- **Compose / Repeat**: send a new or captured request (optionally N times). It goes straight to the server, ignoring system proxy settings, and redirects are shown rather than followed.

- **Diff**: select two requests (⌘-click) and press Compare. Start line, headers (order and case ignored) and body (JSON compared pretty-printed with sorted keys, so formatting is not a difference) are shown line by line, for the request and the response, with an "only changes" view.

### WebSocket

A `101 Switching Protocols` upgrade is relayed byte for byte while a passive parser records every text, binary, close, ping and pong frame (per direction, 1 MB stored per message). `permessage-deflate` is not negotiated so frames stay readable. Messages show in the inspector and in HAR exports.

### Scripting

Tools → Scripting… (⇧⌘J) holds JavaScript scripts (run with the system JavaScriptCore), each with an optional method and URL pattern. A script may define `onRequest(request)` and/or `onResponse(request, response)` and returns the object; `request` is `{method, url, headers, body}` and `response` is `{status, headers, body}`, with headers as a `{Name: value}` object and `body` a string (`null` for binary bodies, which are kept unless you assign a string). Response bodies arrive decompressed, and editing one drops `Content-Encoding`. `console.log` goes to the console panel. Scripts have no network, file or process access. A throwing script leaves the traffic unchanged and adds a note to the flow. JavaScriptCore cannot interrupt a script that never returns, so such a script blocks its own request. Scripts are saved with the other rules in `rules.json`.

### gRPC and Protobuf

Bodies with `application/grpc*` (including gRPC-Web and gRPC-Web-Text) are split into length-prefixed messages and shown in the inspector as raw protobuf (`protoc --decode_raw` style: nested messages, strings, varints, fixed-width values; gzip-compressed messages are inflated), with trailers frames listed. `application/x-protobuf` bodies are decoded the same way. Import `.proto` files with Tools → Import .proto Files… (copied to `~/Library/Application Support/Proxio/protos`) and gRPC messages are shown with field names and types, chosen from the request path `/package.Service/Method`; unknown fields stay raw. Plain `application/x-protobuf` bodies have no method to pick a type from, so they stay schemaless. Not supported: `import` resolution across files (put related messages in one file or import all of them), extensions and groups. Native gRPC is captured too, since intercepted tunnels speak HTTP/2 (see below); trailers such as `grpc-status` are kept and shown.

### HTTP/2 and keep-alive

Client connections to the proxy are kept alive across requests (HTTP/1.1, including inside decrypted tunnels); pipelined requests are answered in order. Inside intercepted CONNECT tunnels the proxy negotiates ALPN (`h2`, `http/1.1`) with the client and with the origin, so HTTP/2 clients are captured, rewritten (breakpoints, Map Local/Remote, scripts) and forwarded, with trailers preserved. An HTTP/2 client can talk to an HTTP/1.1 origin and vice versa. Origin connections are pooled per event loop: idle HTTP/1.1 connections are reused for 30 s (a connection found dead before any response byte is retried once on a fresh one), and an HTTP/2 origin gets one shared connection with a stream per request. WebSocket upgrades, HEAD requests and `Connection: close` responses never reuse a connection. Plain-HTTP and HTTP/1.1 clients are served over HTTP/2 when the origin offers it on TLS.

Limitations: flows held by a breakpoint or script are buffered whole; no flow-control tuning; streaming gRPC is passed through but only decoded per message once complete; opaque (non-intercepted) tunnels are untouched; WebSocket stays HTTP/1.1; there is no h2c on the proxy port.

### Privileged helper (optional)

Changing the system proxy with `networksetup` makes macOS ask for authorization. A build made with `PROXIO_SIGN_IDENTITY="Apple Development: Name (TEAMID)" scripts/bundle.sh` also embeds `ProxioHelper`, a launch daemon registered through `SMAppService`: Settings → System → Install… registers it, and you approve it once in System Settings → Login Items. After that the app asks it over XPC to set the proxy of a network service to `127.0.0.1:<port>` and to restore the previous setting. The helper does nothing else: it validates the port, the service name (it must be a listed network service) and the host characters of a snapshot, and it accepts connections only from `dev.proxio.app` signed by the same team as the helper (checked with a code-signing requirement it derives from its own signature, so an ad-hoc signed helper accepts nobody). If the helper is not installed or does not answer, the app falls back to the direct `networksetup` path. The helper is built and its validation is unit-tested, but registration needs a signed build and a user approval, so it has not been exercised end to end in CI.

### Look and languages

The UI follows the familiar three-panel layout (quick filters, flow table, request/response inspector, Tools menu) with a teal accent and an anchor icon (`scripts/make-icon.sh` regenerates it). It is available in English, Spanish, Russian and French, following the system language. English strings are the keys; translations live in `scripts/l10n-catalog.py`, which writes `Sources/ProxioApp/Localization/*.lproj` and fails if a string in the UI has no translation (`python3 scripts/l10n-catalog.py --check`).

URL patterns are `host[:port]/path?query` globs with `*` (`api.example.com/v1/*`); a bare host matches every path. Rules are saved to `~/Library/Application Support/Proxio/rules.json` and reloaded on launch (an unreadable file is moved to `rules.json.bak`, never overwritten). Bodies sent with `Content-Encoding` gzip, deflate or brotli are shown and exported to HAR decoded; the capture itself keeps the original bytes. HTTPS rules need interception enabled and the host not excluded.

## Mobile devices

Tools → **Set Up Device…** (⇧⌘I) turns on "Allow devices on this network" (the proxy listens on `0.0.0.0` but only answers private-range peers), shows the Mac's LAN address with a QR code, and the steps for iOS/Android. The built-in setup site at `http://<mac-ip>:<port>/` serves the CA as PEM/DER and as an Apple `.mobileconfig` profile. A button installs the CA into booted iOS simulators (`xcrun simctl keychain booted add-root-cert`).

## Sessions

File → **Save Session…** (⌘S) writes every flow, byte-exact, to a `.proxio` file; **Open Session…** (⌘O) replaces the current capture with it. **Import HAR…** appends flows from any HAR 1.x file (browsers, other proxies, Proxio's own export); HAR bodies are already decoded, so `Content-Encoding` is dropped on import.

## Network conditions

Tools → **Network Conditions…** (⇧⌘T) simulates a slow or dead connection for everything going through the proxy: presets (Edge, Slow/Fast 3G, 4G/LTE, Poor Wi-Fi, Offline) or custom latency and download/upload limits. It paces the client-side bytes in both directions (so it also covers HTTPS tunnels and HTTP/2), applies live without restarting, and is never persisted. A status-bar badge shows when it is active.
