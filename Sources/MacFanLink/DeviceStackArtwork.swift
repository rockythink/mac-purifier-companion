import AppKit
import SwiftUI

/// Front elevations: Mac mini (2024) 127 × 50 mm; Mi Air Purifier 2 240 × 520 mm.
/// Sources: support.apple.com/121555 and mi.com/global/air2/specs.
struct DeviceStackArtwork: View {
    let mac: MacDeviceIdentity
    let purifierModel: String?
    let imageURL: String?
    let height: CGFloat
    @State private var artwork = PurifierArtwork.shared
    @State private var photoStore = ProductPhotoStore.shared

    private var calibrated: Bool {
        ["Mac16,10", "Mac16,11"].contains(mac.identifier) && purifierModel == "zhimi.airpurifier.m1"
    }

    var body: some View {
        let scale = height / 570
        let purifierURL = imageURL ?? ProductPhotoStore.fallbackPurifierURL
        // Uncalibrated Macs get a taller photo slot; reserving it even for the
        // schematic fallback keeps the purifier from shifting when the photo lands.
        let macSlot: CGFloat = calibrated ? 50 : 80
        VStack(spacing: 0) {
            Group {
                if let photo = photoStore.photo(for: mac.name) {
                    Image(nsImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: (calibrated ? 127 : 150) * scale, height: macSlot * scale, alignment: .bottom)
                } else {
                    Image(nsImage: mac.frontImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 127 * scale, height: 50 * scale, alignment: .bottom)
                }
            }
            .frame(height: macSlot * scale, alignment: .bottom)
            Group {
                if artwork.url == purifierURL, let image = artwork.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "air.purifier").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 240 * scale, height: (570 - macSlot) * scale)
            .clipped()
        }
        .frame(width: 240 * scale, height: height)
        .accessibilityLabel("Mac 位于空气净化器顶部，固定叠放")
        .help(calibrated ? "机身尺寸同比例：Mac mini 12.7 × 12.7 × 5 cm；净化器 24 × 24 × 52 cm。" : "固定叠放示意；当前型号暂无尺寸标定。")
        .task(id: imageURL) { artwork.load(purifierURL) }
        .task(id: mac.name) { photoStore.load(family: mac.name) }
    }
}

@MainActor
@Observable
private final class PurifierArtwork {
    static let shared = PurifierArtwork()
    private(set) var url: String?
    private(set) var image: NSImage?
    private var request: Task<Void, Never>?

    func load(_ value: String?) {
        guard value != url else { return }
        request?.cancel()
        url = value
        image = nil
        guard let value, let remote = URL(string: value) else { return }
        // Shared by the overview and popup; closing either must not cancel the other's photo.
        request = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                guard !Task.isCancelled, url == value, let source = NSImage(data: data) else { return }
                image = croppedDeviceArtwork(source)
            } catch {
                // Keep the schematic symbol if the photo cannot be loaded.
            }
        }
    }
}

/// Remove transparent canvas once, so physical scale applies to the device, not PNG padding.
@MainActor
func croppedDeviceArtwork(_ image: NSImage, frontAspectRatio: CGFloat? = nil) -> NSImage {
    var proposed = CGRect(x: 0, y: 0, width: 512, height: 512)
    guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return image }
    let factor = min(1, 512 / CGFloat(max(source.width, source.height)))
    let width = max(1, Int(CGFloat(source.width) * factor))
    let height = max(1, Int(CGFloat(source.height) * factor))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
        for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 16 {
            left = min(left, x)
            right = max(right, x)
            top = min(top, y)
            bottom = max(bottom, y)
        }
    }
    guard right >= left, bottom >= top else { return image }
    var bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    if let frontAspectRatio {
        // The system Mac mini artwork includes a top face. Use its front elevation,
        // retaining the feet while omitting that perspective-dependent top surface.
        let frontHeight = min(bounds.height, bounds.width / frontAspectRatio)
        bounds.origin.y = bounds.maxY - frontHeight
        bounds.size.height = frontHeight
    }
    guard let cropped = context.makeImage()?.cropping(to: bounds) else { return image }
    return NSImage(cgImage: cropped, size: bounds.size)
}
