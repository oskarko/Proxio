import Foundation

/// The `.proto` files the user imported, merged into one schema. Files live in `directory` (one copy each) and are re-read on `reload()`.
public final class ProtoRegistry: @unchecked Sendable {
    public static let shared = ProtoRegistry(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Proxio/protos", isDirectory: true))

    public let directory: URL
    private let lock = NSLock()
    private var current = ProtoSchema()

    public init(directory: URL) {
        self.directory = directory
        reload()
    }

    public var schema: ProtoSchema { lock.withLock { current } }

    /// Re-reads every `*.proto` in the directory. Files that do not parse are skipped and returned by name.
    @discardableResult
    public func reload() -> [String] {
        var next = ProtoSchema()
        var bad: [String] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "proto" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8), next.add(source: text) else { bad.append(url.lastPathComponent); continue }
        }
        lock.withLock { current = next }
        return bad
    }

    /// Copies `urls` into the directory (replacing same-named files) and reloads. Returns the names that failed to parse.
    @discardableResult
    public func importFiles(_ urls: [URL]) -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            let dest = directory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        return reload()
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        reload()
    }
}
