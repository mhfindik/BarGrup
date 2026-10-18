import AppKit
import SwiftUI

/// Kalıcı olarak saklanan, başka bir uygulamanın menü çubuğu öğesine referans.
struct ItemRef: Codable, Hashable, Identifiable {
    var bundleID: String
    /// Uygulama içinde öğeyi tanımlayan kararlı kimlik ("id:…", "d:…" ya da "#index").
    var axID: String
    /// Uygulamanın öğeleri arasındaki sıra (yedek eşleştirme için).
    var index: Int
    var displayName: String

    var key: String { "\(bundleID)|\(axID)" }
    var id: String { key }

    static func == (lhs: ItemRef, rhs: ItemRef) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct ItemGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorHex: String
    var symbol: String
    var items: [ItemRef] = []

    static func == (lhs: ItemGroup, rhs: ItemGroup) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.colorHex == rhs.colorHex
            && lhs.symbol == rhs.symbol && lhs.items.map(\.key) == rhs.items.map(\.key)
            && lhs.items.map(\.displayName) == rhs.items.map(\.displayName)
            && lhs.items.map(\.index) == rhs.items.map(\.index)
    }

    var color: NSColor { NSColor(hex: colorHex) ?? .systemBlue }
}

struct AppConfig: Codable, Equatable {
    var groups: [ItemGroup] = []
    /// Gruplanmış öğeler menü çubuğunda gizlensin mi?
    var hidingEnabled = true
    /// Gizli bir öğe açılırken bölümü geçici olarak göster.
    var revealWhenOpening = true
    /// Panelde öğe adlarını göster.
    var showLabels = true
    /// Elle gösterilen gizli bölüm kaç saniye sonra tekrar gizlensin (0 = asla).
    var autoRehideSeconds = 15
    var didShowWelcome = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? []
        hidingEnabled = try c.decodeIfPresent(Bool.self, forKey: .hidingEnabled) ?? true
        revealWhenOpening = try c.decodeIfPresent(Bool.self, forKey: .revealWhenOpening) ?? true
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        autoRehideSeconds = try c.decodeIfPresent(Int.self, forKey: .autoRehideSeconds) ?? 15
        didShowWelcome = try c.decodeIfPresent(Bool.self, forKey: .didShowWelcome) ?? false
    }
}

enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BarGrup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // Bozuk dosyayı kaybetmemek için yedekle.
            let backup = directory.appendingPathComponent("config.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("BarGrup: config okunamadı: \(error)")
            return AppConfig()
        }
    }

    static func save(_ config: AppConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("BarGrup: config kaydedilemedi: \(error)")
        }
    }
}

// MARK: - Renk yardımcıları

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#007AFF" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

enum Palette {
    static let presets: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE",
        "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93",
    ]

    static let symbols: [String] = [
        "star.fill", "heart.fill", "bolt.fill", "folder.fill", "tray.full.fill",
        "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill", "cpu", "chart.bar.fill",
        "network", "wifi", "lock.fill", "key.fill", "eye.fill",
        "bell.fill", "music.note", "play.fill", "cloud.fill", "sun.max.fill",
        "moon.fill", "flame.fill", "leaf.fill", "briefcase.fill", "person.fill",
        "globe", "bubble.left.fill", "doc.fill", "paintbrush.fill", "gamecontroller.fill",
        "sparkles", "square.grid.2x2.fill", "circle.grid.3x3.fill", "shield.fill", "terminal.fill",
        "camera.fill", "keyboard.fill", "display", "battery.100", "clock.fill",
    ]
}

// MARK: - Simge çizimi

enum Icons {
    /// Menü çubuğunda grubu temsil eden renkli simge.
    static func groupIcon(colorHex: String, symbol: String, size: CGFloat = 18, badge: Int? = nil) -> NSImage {
        let color = NSColor(hex: colorHex) ?? .systemBlue
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size * 0.28, yRadius: size * 0.28)
            color.setFill()
            path.fill()
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [contrastingColor(for: color)]))
            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = sym.size
                let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
                sym.draw(in: r)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func contrastingColor(for color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.72 ? NSColor.black.withAlphaComponent(0.85) : .white
    }

    /// Sistem öğeleri: tanıdık bir SF simgesi; diğerleri: uygulamanın kendi simgesi.
    /// (Ekran kaydı izni gerektirmez.)
    static func itemIcon(for ref: ItemRef) -> NSImage {
        if let name = systemSymbol(for: ref),
           let img = NSImage(systemSymbolName: name, accessibilityDescription: ref.displayName) {
            return img
        }
        return appIcon(bundleID: ref.bundleID)
    }

    private static let symbolHints: [(String, String)] = [
        ("battery", "battery.100"), ("clock", "clock"), ("wifi", "wifi"), ("bluetooth", "dot.radiowaves.left.and.right"),
        ("focus", "moon.fill"), ("controlcenter", "switch.2"), ("sound", "speaker.wave.2.fill"), ("volume", "speaker.wave.2.fill"),
        ("display", "display"), ("airdrop", "airplayaudio"), ("nowplaying", "play.circle"), ("screenmirroring", "rectangle.on.rectangle"),
        ("keyboard", "keyboard"), ("textinput", "keyboard"), ("spotlight", "magnifyingglass"), ("siri", "mic.fill"),
        ("user", "person.crop.circle"), ("vpn", "network.badge.shield.half.filled"), ("timemachine", "clock.arrow.circlepath"),
        ("accessibility", "accessibility"), ("liveactivity", "rectangle.badge.checkmark"),
    ]

    private static func systemSymbol(for ref: ItemRef) -> String? {
        let systemBundles = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.Spotlight"]
        guard systemBundles.contains(ref.bundleID) else { return nil }
        let hay = (ref.axID + " " + ref.displayName + " " + ref.bundleID).lowercased()
        return symbolHints.first { hay.contains($0.0) }?.1 ?? "gearshape"
    }

    static func isSystemItem(_ ref: ItemRef) -> Bool {
        ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.Spotlight"].contains(ref.bundleID)
    }

    /// Bir uygulamanın simgesi.
    static func appIcon(bundleID: String) -> NSImage {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Teşhis günlüğü

enum Log {
    private static let queue = DispatchQueue(label: "BarGrup.log")
    static var url: URL { ConfigStore.directory.appendingPathComponent("debug.log") }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let u = url
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               (attrs[.size] as? Int ?? 0) > 512_000 {
                try? FileManager.default.removeItem(at: u)
            }
            if let h = try? FileHandle(forWritingTo: u) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: u)
            }
        }
    }
}
