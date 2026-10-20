import SwiftUI
import ProxioCore

/// Block List, Allow List, DNS Spoofing and Bypass in one place.
struct AccessRulesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private var hint: LocalizedStringKey {
        switch tab {
        case 0: "Matching requests are answered with 403 and never reach the server. A host-wide pattern also refuses HTTPS tunnels that are not intercepted."
        case 1: "While this list has an enabled entry, everything that does not match it is refused with 403. The Block List still wins."
        case 2: "Connect to another address for matching hosts. The certificate name and Host header stay the original."
        default: "HTTPS tunnels to these hosts are relayed untouched and not recorded. Use it for apps that pin certificates."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Block List").tag(0)
                Text("Allow List").tag(1)
                Text("DNS Spoofing").tag(2)
                Text("Bypass").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            List {
                switch tab {
                case 0: accessRows($model.blockList)
                case 1: accessRows($model.allowList)
                case 2:
                    ForEach($model.dnsRules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.isEnabled).labelsHidden()
                            TextField("Host (e.g. api.example.com)", text: $rule.hostPattern)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Address (e.g. 127.0.0.1)", text: $rule.address)
                        }
                    }
                    .onDelete { model.dnsRules.remove(atOffsets: $0) }
                default:
                    ForEach($model.bypassRules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.isEnabled).labelsHidden()
                            TextField("Host (e.g. *.apple.com)", text: $rule.hostPattern)
                        }
                    }
                    .onDelete { model.bypassRules.remove(atOffsets: $0) }
                }
            }
            Divider()
            HStack {
                Button("Add") {
                    switch tab {
                    case 0: model.blockList.append(AccessRule(matcher: RequestMatcher(urlPattern: "example.com/*")))
                    case 1: model.allowList.append(AccessRule(matcher: RequestMatcher(urlPattern: "example.com/*")))
                    case 2: model.dnsRules.append(DNSRule(hostPattern: "example.com", address: "127.0.0.1"))
                    default: model.bypassRules.append(BypassRule(hostPattern: "example.com"))
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func accessRows(_ rules: Binding<[AccessRule]>) -> some View {
        ForEach(rules) { $rule in
            HStack {
                Toggle("", isOn: $rule.isEnabled).labelsHidden()
                TextField("Method", text: $rule.matcher.method.orEmpty).frame(width: 70)
                TextField("URL pattern (e.g. ads.example.com/*)", text: $rule.matcher.urlPattern)
            }
        }
        .onDelete { rules.wrappedValue.remove(atOffsets: $0) }
    }
}
