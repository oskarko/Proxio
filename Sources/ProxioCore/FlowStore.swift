import Foundation

/// Thread-safe in-memory list of captured flows.
public actor FlowStore {
    private var flows: [Flow] = []
    private var observers: [UUID: AsyncStream<[Flow]>.Continuation] = [:]

    public init() {}

    public func add(_ flow: Flow) { flows.append(flow); notify() }

    public func update(_ flow: Flow) {
        if let i = flows.firstIndex(where: { $0.id == flow.id }) { flows[i] = flow; notify() }
    }

    /// Adds a WebSocket message to an existing flow; `closed` also fixes its duration.
    public func append(_ message: WebSocketMessage, to id: UUID) {
        guard let i = flows.firstIndex(where: { $0.id == id }) else { return }
        flows[i].messages.append(message)
        flows[i].duration = message.timestamp.timeIntervalSince(flows[i].startedAt)
        notify()
    }

    public func all() -> [Flow] { flows }

    public func clear() { flows.removeAll(); notify() }

    /// Yields the current flows immediately, then again after every change.
    /// Only the latest snapshot is kept for a slow consumer.
    public nonisolated func changes() -> AsyncStream<[Flow]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Flow].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        Task { await self.addObserver(id, continuation) }
        return stream
    }

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<[Flow]>.Continuation) {
        observers[id] = continuation
        continuation.yield(flows)
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for continuation in observers.values { continuation.yield(flows) }
    }

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
