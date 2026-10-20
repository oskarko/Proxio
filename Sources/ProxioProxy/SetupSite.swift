import Foundation
import ProxioCore

/// The small site a phone reaches by opening the proxy's own address (or `proxio.local` through the proxy):
/// a page with the steps and the root certificate in the formats iOS and Android install.
enum SetupSite {
    static let hostnames: Set<String> = ["proxio.local", "proxio.setup"]

    static func isSetupRequest(uri: String, tunnel: Bool) -> Bool {
        if tunnel { return false }
        if uri.hasPrefix("/") { return true }
        guard let host = URL(string: uri)?.host?.lowercased() else { return false }
        return hostnames.contains(host)
    }

    static func respond(path uri: String, ca: CertificateAuthority?) -> HTTPResponseRecord {
        let path: String
        if uri.hasPrefix("/") { path = uri } else { path = URL(string: uri)?.path ?? "/" }
        let route = path.split(separator: "?").first.map(String.init) ?? "/"

        guard let ca else {
            return page(status: 404, "<h1>HTTPS interception is off</h1><p>Turn on <b>Intercept HTTPS</b> in Proxio and restart the proxy to get a certificate.</p>")
        }
        switch route {
        case "/ca.pem", "/ca.crt":
            guard let pem = try? ca.rootCertificatePEM else { return page(status: 500, "<h1>Certificate unavailable</h1>") }
            return file(Data(pem.utf8), type: "application/x-pem-file", name: "proxio-ca.pem")
        case "/ca.cer":
            guard let der = try? ca.rootCertificateDER else { return page(status: 500, "<h1>Certificate unavailable</h1>") }
            return file(der, type: "application/x-x509-ca-cert", name: "proxio-ca.cer")
        case "/proxio.mobileconfig":
            guard let der = try? ca.rootCertificateDER else { return page(status: 500, "<h1>Certificate unavailable</h1>") }
            return file(MobileConfig.profile(certificateDER: der), type: "application/x-apple-aspen-config", name: "proxio.mobileconfig")
        case "/":
            return page(status: 200, """
            <h1>Proxio</h1>
            <p>This device is connected to Proxio. To read HTTPS traffic, install and trust the root certificate.</p>
            <h2>iPhone / iPad</h2>
            <ol>
              <li><a class="button" href="/proxio.mobileconfig">Download profile</a> and allow it.</li>
              <li>Settings → <b>Profile Downloaded</b> → Install.</li>
              <li>Settings → General → About → <b>Certificate Trust Settings</b> → turn on <b>Proxio Root CA</b>.</li>
            </ol>
            <h2>Android</h2>
            <ol>
              <li><a class="button" href="/ca.cer">Download certificate</a>.</li>
              <li>Settings → Security → Encryption &amp; credentials → Install a certificate → <b>CA certificate</b>.</li>
              <li>Apps that opt out of user certificates (most apps targeting Android 7+) stay opaque.</li>
            </ol>
            <p class="note">Remove the certificate when you are done: anyone holding its private key could impersonate sites to this device.</p>
            """)
        default:
            return page(status: 404, "<h1>Not found</h1>")
        }
    }

    private static func file(_ data: Data, type: String, name: String) -> HTTPResponseRecord {
        HTTPResponseRecord(status: 200, reason: "OK", headers: [
            HTTPHeader(name: "Content-Type", value: type),
            HTTPHeader(name: "Content-Disposition", value: "attachment; filename=\"\(name)\""),
            HTTPHeader(name: "Cache-Control", value: "no-store"),
        ], body: data)
    }

    private static func page(status: Int, _ body: String) -> HTTPResponseRecord {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Proxio</title><style>
        body{font:16px -apple-system,system-ui,sans-serif;max-width:34em;margin:2em auto;padding:0 1em;line-height:1.5;color:#111}
        h1{color:#0a9396}.button{display:inline-block;background:#0a9396;color:#fff;padding:.4em .9em;border-radius:8px;text-decoration:none}
        .note{color:#666;font-size:.9em}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}.note{color:#aaa}}
        </style></head><body>\(body)</body></html>
        """
        return HTTPResponseRecord(status: status, reason: status == 200 ? "OK" : "Error", headers: [
            HTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
            HTTPHeader(name: "Cache-Control", value: "no-store"),
        ], body: Data(html.utf8))
    }
}
