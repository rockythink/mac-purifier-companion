import AppKit
import Darwin
import Observation

@MainActor
@Observable
final class MacDeviceIdentity {
    static let shared = MacDeviceIdentity()

    private(set) var name = "Mac"
    let identifier: String
    private(set) var chip = ""
    let frontImage: NSImage
    private var startedLoading = false

    private init() {
        var count = 0
        if sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 0 {
            var bytes = [CChar](repeating: 0, count: count)
            if sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 {
                identifier = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } else {
                identifier = "型号未知"
            }
        } else {
            identifier = "型号未知"
        }
        let image = NSImage(named: NSImage.computerName)
            ?? NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Mac")!
        let frontRatio: CGFloat? = ["Mac16,10", "Mac16,11"].contains(identifier) ? 127.0 / 50 : nil
        frontImage = croppedDeviceArtwork(image, frontAspectRatio: frontRatio)
    }

    func load() async {
        guard !startedLoading else { return }
        startedLoading = true
        let details = await Task.detached(priority: .utility) {
            Self.readHardwareDetails()
        }.value
        if let details {
            name = details.name
            chip = details.chip
        }
    }

    private nonisolated static func readHardwareDetails() -> (name: String, chip: String)? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hardware = (root["SPHardwareDataType"] as? [[String: Any]])?.first,
                  let name = hardware["machine_name"] as? String, !name.isEmpty else { return nil }
            return (name, hardware["chip_type"] as? String ?? hardware["cpu_type"] as? String ?? "")
        } catch {
            return nil
        }
    }
}
