import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ProxioCore

/// Everything needed to point a phone, tablet or simulator at Proxio.
struct MobileSetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var addresses = LocalNetwork.ipv4Addresses()
    @State private var selected: String?

    private var ip: String? { selected ?? addresses.first?.ip }
    private var setupURL: String? { ip.map { "http://\($0):\(model.port)/" } }

    var body: some View {
        Form {
            Section("Network") {
                Toggle("Allow devices on this network", isOn: $model.allowLAN).disabled(model.isRunning)
                Text("Proxio then listens on all interfaces, but only answers devices on private networks (192.168.x.x, 10.x.x.x, 172.16–31.x.x). Restart the proxy after changing this.")
                    .font(.caption).foregroundStyle(.secondary)
                if addresses.isEmpty {
                    Text("No network address found.").foregroundStyle(.orange)
                } else {
                    Picker("This Mac", selection: Binding(get: { ip ?? "" }, set: { selected = $0 })) {
                        ForEach(addresses) { Text("\($0.ip)  (\($0.interface))").tag($0.ip) }
                    }
                    LabeledContent("Proxy", value: "\(ip ?? "–"):\(model.port)").textSelection(.enabled)
                }
            }
            if model.allowLAN, model.isRunning, let url = setupURL, let image = Self.qr(url) {
                Section("Scan with the phone camera") {
                    HStack {
                        Spacer()
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                        Spacer()
                    }
                    Text(url).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity)
                }
            } else {
                Section { Text(model.allowLAN ? "Start the proxy to see the setup address." : "Turn on “Allow devices on this network” and start the proxy.").foregroundStyle(.secondary) }
            }
            Section("iPhone / iPad") {
                Text("1. Same Wi-Fi as this Mac. Settings → Wi-Fi → (i) → Configure Proxy → Manual: server and port as above.\n2. Open the setup address in Safari, download the profile and install it (Settings → Profile Downloaded).\n3. Settings → General → About → Certificate Trust Settings → trust “Proxio Root CA”.")
                    .font(.callout)
            }
            Section("Android") {
                Text("Wi-Fi → modify network → Proxy: Manual with the server and port above. Open the setup address and install the CA certificate. Apps that ignore user certificates stay opaque.")
                    .font(.callout)
            }
            Section("Simulators") {
                Text("Simulators use this Mac’s proxy settings: turn on “Use as system proxy”, then install the certificate in the running simulators.")
                    .font(.callout)
                HStack {
                    Button("Install Certificate in Booted Simulators") { Task { await model.installCAInSimulators() } }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { addresses = LocalNetwork.ipv4Addresses() }
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
