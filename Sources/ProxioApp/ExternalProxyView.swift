import SwiftUI
import ProxioCore

/// Chain Proxio through another HTTP proxy (corporate proxy, VPN gateway, another debugger).
struct ExternalProxyView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("Send Proxio's outgoing traffic through another HTTP proxy. Every connection uses a CONNECT tunnel, so the proxy must allow CONNECT to the ports you use.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use external proxy", isOn: $model.externalProxy.isEnabled)
            }
            Section("Server") {
                TextField("Host", text: $model.externalProxy.host)
                TextField("Port", value: $model.externalProxy.port, format: .number.grouping(.never))
            }
            .disabled(!model.externalProxy.isEnabled)
            Section("Authentication") {
                TextField("Username", text: $model.externalProxy.username)
                SecureField("Password", text: $model.externalProxy.password)
            }
            .disabled(!model.externalProxy.isEnabled)
            Section("Direct connections") {
                TextField("Hosts that skip the proxy", text: $model.externalProxy.bypass)
                Text("Comma-separated, wildcards allowed. Loopback addresses always go direct.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.externalProxy.isEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
