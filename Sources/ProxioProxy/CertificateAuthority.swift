import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

/// Self-signed root CA that issues short-lived leaf certificates per host,
/// used to terminate TLS for intercepted CONNECT tunnels.
public final class CertificateAuthority: @unchecked Sendable {
    private let key: P256.Signing.PrivateKey
    private let certificate: Certificate
    private let lock = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]

    public static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Proxio", isDirectory: true)

    /// Generates a fresh root CA valid for ten years.
    public init(commonName: String = "Proxio Root CA") throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Proxio")
        }
        let now = Date()
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
        }
        self.key = key
        self.certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
    }

    private init(key: P256.Signing.PrivateKey, certificate: Certificate) {
        self.key = key
        self.certificate = certificate
    }

    /// Loads `ca.pem` from `directory` and the private key from `keyStore` (the login
    /// keychain by default), creating both on first use.
    ///
    /// A legacy `ca-key.pem` is only moved into the key store if `confirmMigration`
    /// returns true; otherwise the file keeps being used, untouched.
    public static func loadOrCreate(
        in directory: URL = defaultDirectory,
        keyStore: CAKeyStore = KeychainKeyStore(),
        confirmMigration: () -> Bool = { false }
    ) throws -> CertificateAuthority {
        let fm = FileManager.default
        let certURL = directory.appendingPathComponent("ca.pem")
        let legacyURL = directory.appendingPathComponent("ca-key.pem")
        let certExists = fm.fileExists(atPath: certURL.path)

        if certExists, let raw = try keyStore.load() {
            let cert = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            return CertificateAuthority(key: try P256.Signing.PrivateKey(rawRepresentation: raw), certificate: cert)
        }
        if certExists, fm.fileExists(atPath: legacyURL.path) {
            let cert = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: legacyURL, encoding: .utf8))
            let ca = CertificateAuthority(key: key, certificate: cert)
            if confirmMigration() { try ca.migrateLegacyKey(at: legacyURL, to: keyStore) }
            return ca
        }
        let ca = try CertificateAuthority()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try keyStore.save(ca.key.rawRepresentation)
        try ca.rootCertificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
        return ca
    }

    /// True when a plaintext `ca-key.pem` still exists in `directory`.
    public static func hasLegacyKey(in directory: URL = defaultDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("ca-key.pem").path)
    }

    /// Saves the key to `keyStore`, verifies it reads back identically, then overwrites
    /// and removes the plaintext file.
    func migrateLegacyKey(at url: URL, to keyStore: CAKeyStore) throws {
        let raw = key.rawRepresentation
        try keyStore.save(raw)
        guard try keyStore.load() == raw else {
            throw CAKeyStoreError(operation: "verify", status: errSecInternalError)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try? Data(count: max(size, 1)).write(to: url)
        try FileManager.default.removeItem(at: url)
    }

    /// Plaintext PEM of the key; only used to build legacy layouts in tests.
    var rootKeyPEM: String { key.pemRepresentation }

    /// The root certificate in DER form (what Android and iOS profiles embed).
    public var rootCertificateDER: Data {
        get throws {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return Data(serializer.serializedBytes)
        }
    }

    public var rootCertificatePEM: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    /// TLS server context presenting a leaf certificate for `host`, cached per host and ALPN list.
    public func serverContext(for host: String, applicationProtocols: [String] = ["h2", "http/1.1"]) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = "\(host)|\(applicationProtocols.joined(separator: ","))"
        if let cached = contexts[cacheKey] { return cached }

        let leafKey = P256.Signing.PrivateKey()
        let now = Date()
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([Self.generalName(for: host)])
            SubjectKeyIdentifier(hash: Certificate.PublicKey(leafKey.publicKey))
        }
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(365 * 86_400),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(host) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key)
        )

        let nioCert = try NIOSSLCertificate(bytes: Array(try leaf.serializeAsPEM().pemString.utf8), format: .pem)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioCert)],
            privateKey: .privateKey(nioKey)
        )
        config.applicationProtocols = applicationProtocols
        let context = try NIOSSLContext(configuration: config)
        contexts[cacheKey] = context
        return context
    }

    static func generalName(for host: String) -> GeneralName {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(withUnsafeBytes(of: v4) { Array($0) })))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(withUnsafeBytes(of: v6) { Array($0) })))
        }
        return .dnsName(host)
    }
}
