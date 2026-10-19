import SwiftUI
import ProxioCore

struct DiffView: View {
    let a: Flow
    let b: Flow
    @Environment(\.dismiss) private var dismiss
    @State private var side: Side = .response
    @State private var onlyChanges = true
    private let diff: FlowDiff

    enum Side: String, CaseIterable { case request = "Request", response = "Response" }

    init(a: Flow, b: Flow) {
        self.a = a
        self.b = b
        diff = FlowDiff.compare(a, b)
    }

    private var message: MessageDiff? { side == .request ? diff.request : diff.response }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                label("−", a, .red)
                label("+", b, .green)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            HStack {
                Picker("", selection: $side) {
                    ForEach(Side.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Toggle("Only changes", isOn: $onlyChanges).toggleStyle(.checkbox)
                Spacer()
                if let message { Text(LocalizedStringKey(message.isIdentical ? "Identical" : "Different")).foregroundStyle(message.isIdentical ? .green : .orange) }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if let message {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Start line", message.startLine)
                        section("Headers", message.headers)
                        section("Body", message.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Neither request has a response", systemImage: "hourglass")
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 860, height: 620)
    }

    private func label(_ sign: String, _ flow: Flow, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(sign).bold().foregroundStyle(color)
            Text("\(flow.request.method) \(flow.request.url.absoluteString)").lineLimit(1).truncationMode(.middle)
            if let status = flow.response?.status { Text("→ \(status)").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ lines: [DiffLine]) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        let rows = DiffRow.rows(lines, onlyChanges: onlyChanges)
        if lines.isEmpty {
            Text("(empty)").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12)
        } else if rows.isEmpty {
            Text("No differences").font(.caption).foregroundStyle(.green).padding(.horizontal, 12)
        }
        ForEach(rows) { row in
            switch row.content {
            case .line(let line):
                HStack(spacing: 8) {
                    Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(color(line.kind))
                    Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                }
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.14))
            case .gap(let count):
                Text(count == 1 ? String(localized: "⋯ 1 unchanged line") : String(localized: "⋯ \(count) unchanged lines")).font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 2)
            }
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: .secondary
        case .added: .green
        case .removed: .red
        }
    }
}

/// A diff line or a collapsed run of unchanged ones.
struct DiffRow: Identifiable {
    enum Content { case line(DiffLine), gap(Int) }
    let id: Int
    let content: Content

    /// With `onlyChanges`, unchanged runs keep `context` lines around each change; an all-unchanged section yields no rows.
    static func rows(_ lines: [DiffLine], onlyChanges: Bool, context: Int = 2) -> [DiffRow] {
        guard onlyChanges else { return lines.enumerated().map { DiffRow(id: $0.offset, content: .line($0.element)) } }
        guard lines.contains(where: { $0.kind != .same }) else { return [] }
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, line) in lines.enumerated() where line.kind != .same {
            for j in max(0, i - context)...min(lines.count - 1, i + context) { keep[j] = true }
        }
        var rows: [DiffRow] = []
        var skipped = 0
        for (i, line) in lines.enumerated() {
            if keep[i] {
                if skipped > 0 { rows.append(DiffRow(id: -i, content: .gap(skipped))); skipped = 0 }
                rows.append(DiffRow(id: i, content: .line(line)))
            } else { skipped += 1 }
        }
        if skipped > 0 { rows.append(DiffRow(id: -lines.count, content: .gap(skipped))) }
        return rows
    }
}
