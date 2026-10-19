# Proxio spec (clean-room)

Written from observable behaviour and the public list of open-source building blocks a comparable app ships with. No decompiled code, assets, icons or strings are reused.

## Architecture (target)

| Layer | Responsibility | Building block |
| --- | --- | --- |
| ProxioCore | Flow model, store, filters, HAR import/export | pure Swift |
| ProxioProxy | Listener, HTTP/1.1 + CONNECT, TLS MITM, per-host leaf certs | swift-nio, swift-nio-ssl, swift-certificates |
| ProxioHelper | Privileged helper that sets the system proxy (SMAppService / XPC) | ServiceManagement |
| ProxioApp | AppKit/SwiftUI UI | HexFiend (hex view), Sparkle (updates), Monaco/CodeMirror in WKWebView (body editor) |

## MVP (milestone 1)

1. Proxy engine: plain HTTP forward proxy, CONNECT tunnelling, then TLS interception with a generated root CA.
2. Root CA: generate, store in Keychain, install and trust on request.
3. System proxy: enable/disable the macOS HTTP/HTTPS proxy for the active network service.
4. UI: three areas. Sidebar grouping by app and domain, flow list (method, URL, status, size, time), inspector with Request/Response tabs (headers, query, JSON tree, raw, hex, image preview).
5. Filter and search bar. SSL-proxying allow/deny list.
6. Import/export HAR; copy as cURL.

## Milestone 2

Breakpoints, Map Local, Map Remote, Compose/Repeat, Diff.

## Milestone 3

WebSocket, gRPC/Protobuf, JS scripting, iOS simulator and device setup, CLI.
