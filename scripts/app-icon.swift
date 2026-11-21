// Draws Runbar's app icon and writes it as an .icns: `swift scripts/app-icon.swift Resources/AppIcon.icns`
// (`make icon`). The `>_` mark in glass on a green tile: each bar of the chevron is a slab of glass with
// its own thickness and shadow, and the underscore is the cursor, lit. Every size is drawn from the
// shapes, not scaled down from the largest one.
import AppKit
import SwiftUI

func rgb(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

/// One bar of the chevron: a translucent fill, light caught along the top, a rim brighter at the
/// top-left, and under it the same shape, deeper, for the glass's thickness.
struct GlassBar: View {
    let w: CGFloat, h: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: h * 0.34, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(0.16))
                .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 2))
                .offset(y: h * 0.16)
            shape.fill(Color.white.opacity(0.34))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.42), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))))
                .overlay(shape.fill(LinearGradient(colors: [.clear, .white.opacity(0.18)], startPoint: UnitPoint(x: 0.5, y: 0.7), endPoint: .bottom)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.12), .white.opacity(0.55)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3.5))
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 10)
    }
}

/// On Apple's 1024 grid: the tile is 824 wide with continuous corners, 100 in from each edge.
struct AppIcon: View {
    /// The mark's bars on its 48 grid (`Logo.swift` draws the same): left edge and top of each.
    let bars: [(CGFloat, CGFloat)] = [(4, 4), (10, 10), (16, 16), (22, 22), (16, 28), (10, 34), (4, 40)]
    /// One unit of that grid here; bars are 5 units tall in place of the mark's 4, so the chevron reads as one form.
    let u: CGFloat = 13.5

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let cursor = RoundedRectangle(cornerRadius: 5 * u * 0.34, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(colors: [rgb(0x6BEBB0), rgb(0x1BB06B), rgb(0x085A34)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(tile.fill(RadialGradient(colors: [.white.opacity(0.3), .clear], center: UnitPoint(x: 0.22, y: 0.1), startRadius: 0, endRadius: 560)))
                .overlay(tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.03), .white.opacity(0.34)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 5))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.32), radius: 26, y: 18)
            ZStack(alignment: .topLeading) {
                ForEach(0..<bars.count, id: \.self) { i in
                    GlassBar(w: 12 * u, h: 5 * u)
                        .offset(x: bars[i].0 * u, y: (bars[i].1 - 0.5) * u)
                }
                cursor.fill(Color.white)
                    .overlay(cursor.strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
                    .frame(width: 16 * u, height: 5 * u)
                    .shadow(color: .white.opacity(0.75), radius: 26)
                    .shadow(color: .white.opacity(0.75), radius: 8)
                    .offset(x: 28 * u, y: 39.5 * u)
            }
            .frame(width: 48 * u, height: 48 * u, alignment: .topLeading)
        }
        .frame(width: 1024, height: 1024)
    }
}

let args = CommandLine.arguments
guard args.count == 2, args[1].hasSuffix(".icns") else {
    FileHandle.standardError.write("usage: swift scripts/app-icon.swift <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

MainActor.assumeIsolated {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let renderer = ImageRenderer(content: AppIcon())
            renderer.scale = CGFloat(px) / 1024
            renderer.isOpaque = false
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("couldn't draw the icon at \(px) px")
            }
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try! png.write(to: iconset.appendingPathComponent(name))
        }
    }
}

try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("✓ \(out.path)")
