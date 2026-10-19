import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Seam over `Process` so system-changing code can be tested without touching the machine.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public struct SystemCommandError: Error, CustomStringConvertible {
    public let command: String
    public let result: CommandResult
    public var description: String {
        "`\(command)` exited with \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain before waiting so large output cannot fill the pipe and deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

extension CommandRunner {
    /// Runs and throws `SystemCommandError` on a non-zero exit.
    @discardableResult
    func check(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let result = try run(executable, arguments)
        guard result.status == 0 else {
            throw SystemCommandError(command: ([executable] + arguments).joined(separator: " "), result: result)
        }
        return result
    }
}
