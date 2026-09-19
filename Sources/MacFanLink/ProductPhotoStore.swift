import AppKit

/// Real product photos fetched at runtime and cached on disk.
/// Nothing is bundled into the app; failures keep the existing schematic fallbacks.
@MainActor
@Observable
final class ProductPhotoStore {
    static let shared = ProductPhotoStore()

    /// Generic purifier photo used before a device is paired.
    /// Mirrors the `zhimi.airpurifier.m1` entry in model-catalog.json.
    static let fallbackPurifierURL = "https://cnbj1.fds.api.xiaomi.com/iotweb-product-center/100.png?GalaxyAccessKeyId=AKVGLQWBOVIRQ3XLEW&Expires=9223372036854775807&Signature=m8rTUCSC4C5WVQ3OKdRlrM+0jI0="

    /// Apple Store CDN image ids keyed by `system_profiler` machine name.
    /// Family-level accuracy: a 13" Air and a 15" Air share the Air photo.
    private static let macPhotoIDs: [String: String] = [
        "Mac mini": "mac-mini-hero-202410",
        "Mac Studio": "mac-studio-hero-202503",
        "MacBook Air": "mba13-skyblue-select-202503",
        "MacBook Pro": "mbp14-spaceblack-select-202410",
        "iMac": "imac-24-blue-cto-hero-202310",
    ]

    private(set) var photos: [String: NSImage] = [:]
    private var completed: Set<String> = []
    private let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("cc.ss-data.MacFanLink/ProductPhotos", isDirectory: true)

    func photo(for family: String) -> NSImage? { photos[family] }

    /// Idempotent: each family resolves at most once per launch, disk cache short-circuits the network.
    func load(family: String) {
        guard Self.macPhotoIDs[family] != nil, !completed.contains(family) else { return }
        completed.insert(family)
        Task { await resolve(family: family) }
    }

    private func resolve(family: String) async {
        guard let id = Self.macPhotoIDs[family] else { return }
        if let file = cacheFile(id: id),
           let data = try? Data(contentsOf: file),
           let image = NSImage(data: data) {
            photos[family] = croppedDeviceArtwork(image)
            return
        }
        var components = URLComponents(string: "https://store.storeimages.cdn-apple.com/4982/as-images.apple.com/is/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "wid", value: "512"),
            URLQueryItem(name: "hei", value: "512"),
            URLQueryItem(name: "fmt", value: "png-alpha"),
        ]
        guard let url = components?.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return }
            photos[family] = croppedDeviceArtwork(image)
            if let file = cacheFile(id: id) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        } catch {
            // Offline or CDN change: the caller keeps its schematic fallback.
        }
    }

    private func cacheFile(id: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(id).png")
    }
}
