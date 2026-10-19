import Foundation

/// Installs the Proxio root CA into the current user's login keychain as a trusted root.
/// macOS asks the user to authorise the change; nothing here runs unless a caller invokes it.
public struct CATrust: Sendable {
    public static let securityTool = "/usr/bin/security"
    public static let certificateName = "Proxio Root CA"

    private let runner: CommandRunner
    private let keychain: String

    public init(
        runner: CommandRunner = ProcessRunner(),
        keychain: String = NSString(string: "~/Library/Keychains/login.keychain-db").expandingTildeInPath
    ) {
        self.runner = runner
        self.keychain = keychain
    }

    /// The exact command `install` will run, for showing to the user before asking for confirmation.
    public func installCommand(certificate: URL) -> [String] {
        [Self.securityTool, "add-trusted-cert", "-r", "trustRoot", "-k", keychain, certificate.path]
    }

    /// True when the system evaluates the certificate as a trusted root (read-only check).
    public func isTrusted(certificate: URL) throws -> Bool {
        try runner.run(Self.securityTool, ["verify-cert", "-c", certificate.path, "-p", "basic"]).status == 0
    }

    public func install(certificate: URL) throws {
        try runner.check(Self.securityTool, Array(installCommand(certificate: certificate).dropFirst()))
    }

    /// Removes the trust setting and the certificate from the login keychain.
    public func uninstall(certificate: URL) throws {
        try runner.check(Self.securityTool, ["remove-trusted-cert", certificate.path])
        try runner.check(Self.securityTool, ["delete-certificate", "-c", Self.certificateName, keychain])
    }
}
