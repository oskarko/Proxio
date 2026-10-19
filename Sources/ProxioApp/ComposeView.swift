import SwiftUI
import ProxioCore

extension AppModel {
    /// Opens the composer, pre-filled from `flow` when given.
    func compose(from flow: Flow? = nil) {
        composeDraft = flow?.request ?? HTTPRequestRecord(
            method: "GET", url: URL(string: "https://example.com/")!,
            headers: [HTTPHeader(name: "Accept", value: "*/*")]
        )
    }

    func repeatRequest(_ flow: Flow) {
        send(flow.request, times: 1, note: "Repeat")
    }

    /// Sends `request` sequentially `times` times; every exchange appears in the list.
    func send(_ request: HTTPRequestRecord, times: Int, note: String) {
        Task {
            for _ in 0..<max(1, times) {
                let flow = await RequestSender().send(request, note: note)
                await store.add(flow)
                selection = [flow.id]
                hostFilter = nil
            }
        }
    }
}

struct ComposeView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var method = "GET"
    @State private var url = ""
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var bodyIsBinary = false
    @State private var original = Data()
    @State private var times = 1
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Compose", systemImage: "square.and.pencil").font(.headline)
            HStack {
                Picker("", selection: $method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0) }
                }
                .labelsHidden().frame(width: 100)
                TextField("URL", text: $url)
            }
            Text("Headers (Name: value, one per line)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $headers).font(.body.monospaced()).frame(height: 120).border(.separator)
            Text(bodyIsBinary ? String(localized: "Body is binary (\(BodyFormatter.byteCount(original.count))) and is sent unchanged") : String(localized: "Body"))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bodyText).font(.body.monospaced()).frame(minHeight: 120).border(.separator).disabled(bodyIsBinary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Stepper("Send \(times)×", value: $times, in: 1...100)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { send() }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 640, height: 540)
        .onAppear(perform: load)
    }

    private func load() {
        guard let draft = model.composeDraft else { return }
        method = draft.method
        url = draft.url.absoluteString
        headers = HeaderText.format(draft.headers)
        original = draft.body
        if let text = String(data: draft.body, encoding: .utf8) { bodyText = text } else { bodyIsBinary = true }
    }

    private func send() {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else {
            error = String(localized: "Enter a full http:// or https:// URL"); return
        }
        let request = HTTPRequestRecord(
            method: method, url: u, headers: HeaderText.parse(headers),
            body: bodyIsBinary ? original : Data(bodyText.utf8)
        )
        model.send(request, times: times, note: "Compose")
        dismiss()
    }
}
