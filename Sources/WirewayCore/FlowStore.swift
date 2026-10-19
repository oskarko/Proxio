import Foundation

/// Thread-safe in-memory list of captured flows.
public actor FlowStore {
    private var flows: [Flow] = []

    public init() {}

    public func add(_ flow: Flow) { flows.append(flow) }

    public func update(_ flow: Flow) {
        if let i = flows.firstIndex(where: { $0.id == flow.id }) { flows[i] = flow }
    }

    public func all() -> [Flow] { flows }

    public func clear() { flows.removeAll() }

    /// Case-insensitive match on URL, method, status or MIME type.
    public func search(_ text: String) -> [Flow] {
        guard !text.isEmpty else { return flows }
        return flows.filter { f in
            f.request.url.absoluteString.localizedCaseInsensitiveContains(text)
                || f.request.method.localizedCaseInsensitiveContains(text)
                || (f.response.map { String($0.status) }?.contains(text) ?? false)
                || (f.response?.mimeType.localizedCaseInsensitiveContains(text) ?? false)
        }
    }
}
