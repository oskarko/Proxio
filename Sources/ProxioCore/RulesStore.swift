import Foundation

/// Everything the user configures that should survive a restart.
public struct RulesDocument: Codable, Sendable, Equatable {
    public var breakpoints: [Breakpoint] = []
    public var mapLocal: [MapLocalRule] = []
    public var mapRemote: [MapRemoteRule] = []
    public init(breakpoints: [Breakpoint] = [], mapLocal: [MapLocalRule] = [], mapRemote: [MapRemoteRule] = []) {
        self.breakpoints = breakpoints
        self.mapLocal = mapLocal
        self.mapRemote = mapRemote
    }
}

/// Reads and writes the rules as JSON. Not for secrets: it is a plain file.
public struct RulesStore: Sendable {
    public let url: URL

    public init(url: URL = RulesStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Proxio/rules.json")
    }

    /// A missing file is an empty document. An unreadable one is moved to `rules.json.bak`
    /// (so the next save cannot destroy it) and also yields an empty document.
    public func load() -> RulesDocument {
        guard let data = try? Data(contentsOf: url) else { return RulesDocument() }
        if let document = try? JSONDecoder().decode(RulesDocument.self, from: data) { return document }
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        return RulesDocument()
    }

    public func save(_ document: RulesDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
