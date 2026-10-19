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

    /// Loads `ca.pem` / `ca-key.pem` from `directory`, creating them on first use.
    public static func loadOrCreate(in directory: URL = defaultDirectory) throws -> CertificateAuthority {
        let fm = FileManager.default
        let certURL = directory.appendingPathComponent("ca.pem")
        let keyURL = directory.appendingPathComponent("ca-key.pem")
        if fm.fileExists(atPath: certURL.path), fm.fileExists(atPath: keyURL.path) {
            let cert = try Certificate(pemEncoded: String(contentsOf: certURL, encoding: .utf8))
            let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: keyURL, encoding: .utf8))
            return CertificateAuthority(key: key, certificate: cert)
        }
        let ca = try CertificateAuthority()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try ca.rootCertificatePEM.write(to: certURL, atomically: true, encoding: .utf8)
        try ca.rootKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return ca
    }

    public var rootCertificatePEM: String {
        get throws { try certificate.serializeAsPEM().pemString }
    }

    public var rootKeyPEM: String { key.pemRepresentation }

    /// TLS server context presenting a leaf certificate for `host`, cached per host.
    public func serverContext(for host: String) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached = contexts[host] { return cached }

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
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        contexts[host] = context
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
