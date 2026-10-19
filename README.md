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
