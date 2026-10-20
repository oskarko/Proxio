import Foundation

/// Everything the user configures that should survive a restart.
public struct RulesDocument: Codable, Sendable, Equatable {
    public var breakpoints: [Breakpoint] = []
    public var mapLocal: [MapLocalRule] = []
    public var mapRemote: [MapRemoteRule] = []
    public var scripts: [ProxioScript] = []
    public var blockList: [AccessRule] = []
    public var allowList: [AccessRule] = []
    public var dns: [DNSRule] = []
    public var bypass: [BypassRule] = []
    public var externalProxy = ExternalProxy()
    public init(breakpoints: [Breakpoint] = [], mapLocal: [MapLocalRule] = [], mapRemote: [MapRemoteRule] = [], scripts: [ProxioScript] = [],
                blockList: [AccessRule] = [], allowList: [AccessRule] = [], dns: [DNSRule] = [], bypass: [BypassRule] = [], externalProxy: ExternalProxy = ExternalProxy()) {
        self.externalProxy = externalProxy
        self.blockList = blockList
        self.allowList = allowList
        self.dns = dns
        self.bypass = bypass
        self.breakpoints = breakpoints
        self.mapLocal = mapLocal
        self.mapRemote = mapRemote
        self.scripts = scripts
    }

    // Files saved before scripting existed have no "scripts" key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        breakpoints = try c.decodeIfPresent([Breakpoint].self, forKey: .breakpoints) ?? []
        mapLocal = try c.decodeIfPresent([MapLocalRule].self, forKey: .mapLocal) ?? []
        mapRemote = try c.decodeIfPresent([MapRemoteRule].self, forKey: .mapRemote) ?? []
        scripts = try c.decodeIfPresent([ProxioScript].self, forKey: .scripts) ?? []
        blockList = try c.decodeIfPresent([AccessRule].self, forKey: .blockList) ?? []
        allowList = try c.decodeIfPresent([AccessRule].self, forKey: .allowList) ?? []
        dns = try c.decodeIfPresent([DNSRule].self, forKey: .dns) ?? []
        bypass = try c.decodeIfPresent([BypassRule].self, forKey: .bypass) ?? []
        externalProxy = try c.decodeIfPresent(ExternalProxy.self, forKey: .externalProxy) ?? ExternalProxy()
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
