# Proxio

Free, open-source (MIT) native macOS HTTP/HTTPS debugging proxy. Inspect, filter and export the traffic of your apps.

Status: early. Working today: plain HTTP forwarding with capture, CONNECT tunnelling (opaque, no TLS interception yet), flow store with search, HAR export.

```
swift test
swift run proxio-cli 9090   # then point a client at 127.0.0.1:9090
curl -x http://127.0.0.1:9090 http://example.com/
```

Proxio is an independent clean-room project. It is not affiliated with any commercial proxy tool and contains no code or assets from one.
