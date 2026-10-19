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

The root CA is never installed or trusted automatically. Clients only accept intercepted TLS if you explicitly trust `ca.pem`. Keep `ca-key.pem` private (it is written with mode 0600): anyone holding it can impersonate sites to a device that trusts the CA.

Proxio is an independent clean-room project. It is not affiliated with any commercial proxy tool and contains no code or assets from one.

## App

`scripts/bundle.sh` builds `build/Proxio.app` (ad-hoc signed). The window has three panels: domains, flow list, inspector. The CA and system proxy are only changed after you confirm the exact command in a dialog.

### Rewrite and replay

- **Breakpoints**: pause matching requests and/or responses, edit method, URL, headers, status and body, then execute or cancel (cancelled traffic answers 499). Response breakpoints ask the server for an uncompressed body so it stays editable.
- **Map Local**: answer matching requests from a file (read on every hit) or inline text, with status and headers; "Map Local with This Response" in the flow menu pre-fills it from a capture.
- **Map Remote**: send matching requests to another scheme, host, port or path.
- **Compose / Repeat**: send a new or captured request (optionally N times). It goes straight to the server, ignoring system proxy settings, and redirects are shown rather than followed.

- **Diff**: select two requests (⌘-click) and press Compare. Start line, headers (order and case ignored) and body (JSON compared pretty-printed with sorted keys, so formatting is not a difference) are shown line by line, for the request and the response, with an "only changes" view.

URL patterns are `host[:port]/path?query` globs with `*` (`api.example.com/v1/*`); a bare host matches every path. Rules are saved to `~/Library/Application Support/Proxio/rules.json` and reloaded on launch (an unreadable file is moved to `rules.json.bak`, never overwritten). Bodies sent with `Content-Encoding` gzip, deflate or brotli are shown and exported to HAR decoded; the capture itself keeps the original bytes. HTTPS rules need interception enabled and the host not excluded.
