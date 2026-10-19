import SwiftUI
import AppKit

extension Color {
    /// Proxio's accent: aqua green.
    static let proxioAccent = Color(red: 0.0, green: 0.70, blue: 0.66)
    static let proxioAccentDark = Color(red: 0.0, green: 0.45, blue: 0.47)
}

/// A ship's anchor, stroked in a unit square: ring, shank, stock and curved arms with flukes.
struct AnchorShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        // Ring
        let ring = 0.065
        path.addEllipse(in: CGRect(x: p(0.5 - ring, 0.16 - ring).x, y: p(0, 0.16 - ring).y, width: 2 * ring * rect.width, height: 2 * ring * rect.height))
        // Shank and stock
        path.move(to: p(0.5, 0.16 + ring)); path.addLine(to: p(0.5, 0.82))
        path.move(to: p(0.37, 0.31)); path.addLine(to: p(0.63, 0.31))
        // Arms: an arc under the shank from the left fluke to the right fluke
        let center = (x: 0.5, y: 0.52), radius = 0.30
        let steps = 48
        for i in 0...steps {
            let angle = (165.0 - 150.0 * Double(i) / Double(steps)) * .pi / 180
            let point = p(center.x + radius * cos(angle), center.y + radius * sin(angle))
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        // Flukes
        for sign in [-1.0, 1.0] {
            let angle = (sign < 0 ? 165.0 : 15.0) * .pi / 180
            let tip = (x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            path.move(to: p(tip.x, tip.y)); path.addLine(to: p(tip.x + sign * 0.02, tip.y - 0.13))
            path.move(to: p(tip.x, tip.y)); path.addLine(to: p(tip.x - sign * 0.10, tip.y - 0.045))
        }
        return path
    }
}

struct AnchorMark: View {
    var lineWidthRatio = 0.045
    var body: some View {
        GeometryReader { geo in
            AnchorShape().stroke(style: StrokeStyle(lineWidth: geo.size.width * lineWidthRatio, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct AppIconArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1024 * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [.proxioAccent, .proxioAccentDark], startPoint: .topLeading, endPoint: .bottomTrailing))
            AnchorMark(lineWidthRatio: 0.05).foregroundStyle(.white).padding(190)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
enum IconRenderer {
    /// `Proxio --render-icon <file.png>` writes the 1024 px app icon and exits.
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-icon"), args.indices.contains(flag + 1) else { return }
        let renderer = ImageRenderer(content: AppIconArtwork())
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not render the icon\n".utf8)); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: args[flag + 1])) } catch { print(error); exit(1) }
        exit(0)
    }
}
