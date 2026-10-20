import SwiftUI
import ProxioCore

/// Pick a simulated connection (latency, bandwidth, offline) for all proxied traffic.
struct NetworkConditionsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let customName = "Custom"

    var body: some View {
        Form {
            Section {
                Text("Slows down or cuts off everything that goes through Proxio, in both directions, without restarting. It applies to new data immediately.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Profile", selection: $model.networkChoice) {
                    ForEach(NetworkProfile.presets) { Text(LocalizedStringKey($0.name)).tag($0.name) }
                    Text("Custom").tag(Self.customName)
                }
            }
            if model.networkChoice == Self.customName {
                Section("Custom") {
                    TextField("Added latency (ms, round trip)", value: $model.customProfile.latencyMs, format: .number)
                    TextField("Download limit (kbit/s, 0 = unlimited)", value: $model.customProfile.downKbps, format: .number)
                    TextField("Upload limit (kbit/s, 0 = unlimited)", value: $model.customProfile.upKbps, format: .number)
                    Toggle("Offline", isOn: $model.customProfile.offline)
                }
            } else if !model.networkProfile.isTransparent {
                Section {
                    if model.networkProfile.offline {
                        Text("No connections are accepted.")
                    } else {
                        LabeledContent("Latency", value: "\(model.networkProfile.latencyMs) ms")
                        LabeledContent("Download", value: "\(model.networkProfile.downKbps) kbit/s")
                        LabeledContent("Upload", value: "\(model.networkProfile.upKbps) kbit/s")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
