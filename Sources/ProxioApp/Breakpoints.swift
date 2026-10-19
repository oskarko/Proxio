import SwiftUI
import ProxioCore

/// A message held at a breakpoint until the user releases or cancels it.
struct PausedMessage: Identifiable {
    enum Content {
        case request(HTTPRequestRecord)
        case response(HTTPResponseRecord, for: HTTPRequestRecord)
    }
    enum Edited {
        case request(HTTPRequestRecord)
        case response(HTTPResponseRecord)
    }
    let id = UUID()
    let content: Content
    let release: (Edited?) -> Void
}

/// Lets the proxy (any thread) wait on the user (main actor).
final class BreakpointBridge: BreakpointHandler, @unchecked Sendable {
    weak var model: AppModel?

    func resume(request: HTTPRequestRecord) async -> HTTPRequestRecord? {
        guard let model else { return request }
        return await model.pause(request: request)
    }

    func resume(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord? {
        guard let model else { return response }
        return await model.pause(response: response, for: request)
    }
}

extension AppModel {
    func pause(request: HTTPRequestRecord) async -> HTTPRequestRecord? {
        await withCheckedContinuation { continuation in
            paused.append(PausedMessage(content: .request(request)) { edited in
                if case .request(let r)? = edited { continuation.resume(returning: r) } else { continuation.resume(returning: nil) }
            })
        }
    }

    func pause(response: HTTPResponseRecord, for request: HTTPRequestRecord) async -> HTTPResponseRecord? {
        await withCheckedContinuation { continuation in
            paused.append(PausedMessage(content: .response(response, for: request)) { edited in
                if case .response(let r)? = edited { continuation.resume(returning: r) } else { continuation.resume(returning: nil) }
            })
        }
    }

    func release(_ message: PausedMessage, with edited: PausedMessage.Edited?) {
        paused.removeAll { $0.id == message.id }
        message.release(edited)
    }

    func addBreakpoint(for flow: Flow) {
        let host = flow.request.url.host ?? "*"
        let port = flow.request.url.port.map { ":\($0)" } ?? ""
        breakpoints.append(Breakpoint(matcher: RequestMatcher(urlPattern: host + port + "/*")))
    }
}

// MARK: - Rule list

struct BreakpointsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Breakpoints pause matching traffic so you can edit it before it continues. Only works while the proxy is running; HTTPS needs interception on.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
            List {
                ForEach($model.breakpoints) { $bp in
                    HStack {
                        Toggle("", isOn: $bp.isEnabled).labelsHidden()
                        Picker("", selection: Binding(get: { bp.matcher.method ?? "" }, set: { bp.matcher.method = $0.isEmpty ? nil : $0 })) {
                            Text("Any").tag("")
                            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 80)
                        TextField("host/path pattern, * allowed", text: $bp.matcher.urlPattern).textFieldStyle(.roundedBorder)
                        Toggle("Req", isOn: $bp.onRequest).toggleStyle(.checkbox)
                        Toggle("Res", isOn: $bp.onResponse).toggleStyle(.checkbox)
                    }
                }
                .onDelete { model.breakpoints.remove(atOffsets: $0) }
            }
            .overlay { if model.breakpoints.isEmpty { ContentUnavailableView("No breakpoints", systemImage: "pause.circle") } }
            HStack {
                Button("Add") { model.breakpoints.append(Breakpoint(matcher: RequestMatcher(urlPattern: "*"))) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 600, height: 380)
    }
}

// MARK: - Editor for a paused message

struct PausedEditor: View {
    let message: PausedMessage
    let model: AppModel

    @State private var method = ""
    @State private var url = ""
    @State private var status = 200
    @State private var reason = ""
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var bodyIsBinary = false
    @State private var original = Data()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isRequest ? "Request paused" : "Response paused", systemImage: "pause.circle.fill").font(.headline)
            if isRequest {
                HStack {
                    TextField("Method", text: $method).frame(width: 90)
                    TextField("URL", text: $url)
                }
            } else {
                HStack {
                    TextField("Status", value: $status, format: .number.grouping(.never)).frame(width: 70)
                    TextField("Reason", text: $reason)
                }
            }
            Text("Headers (Name: value, one per line)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $headers).font(.body.monospaced()).frame(height: 130).border(.separator)
            Text(bodyIsBinary ? "Body is binary (\(BodyFormatter.byteCount(original.count))) and is kept unchanged" : "Body")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bodyText).font(.body.monospaced()).frame(minHeight: 130).border(.separator).disabled(bodyIsBinary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("\(model.paused.count) paused").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Request", role: .destructive) { model.release(message, with: nil) }
                Button("Execute") { execute() }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 640, height: 560)
        .interactiveDismissDisabled()
        .onAppear(perform: load)
    }

    private var isRequest: Bool { if case .request = message.content { true } else { false } }

    private func load() {
        switch message.content {
        case .request(let r):
            method = r.method; url = r.url.absoluteString; fill(r.headers, r.body)
        case .response(let r, _):
            status = r.status; reason = r.reason; fill(r.headers, r.body)
        }
    }

    private func fill(_ list: [HTTPHeader], _ body: Data) {
        headers = list.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        original = body
        if let text = String(data: body, encoding: .utf8) { bodyText = text } else { bodyIsBinary = true }
    }

    private func parsedHeaders() -> [HTTPHeader] {
        headers.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return HTTPHeader(
                name: line[..<colon].trimmingCharacters(in: .whitespaces),
                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    private func execute() {
        let body = bodyIsBinary ? original : Data(bodyText.utf8)
        switch message.content {
        case .request(var r):
            guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.host != nil else {
                error = "The URL is not valid"; return
            }
            r.method = method.trimmingCharacters(in: .whitespaces).uppercased()
            r.url = u; r.headers = parsedHeaders(); r.body = body
            model.release(message, with: .request(r))
        case .response(var r, _):
            guard (100...599).contains(status) else { error = "Status must be between 100 and 599"; return }
            r.status = status; r.reason = reason; r.headers = parsedHeaders(); r.body = body
            model.release(message, with: .response(r))
        }
    }
}
