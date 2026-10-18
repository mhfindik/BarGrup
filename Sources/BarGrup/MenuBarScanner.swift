import AppKit
import ApplicationServices

/// Taramada bulunan canlı bir menü çubuğu öğesi.
final class MenuBarItem: Identifiable {
    let ref: ItemRef
    let element: AXUIElement
    /// Global ekran koordinatları (sol üst köşe orijinli, CoreGraphics/AX düzeni).
    let frame: CGRect
    let pid: pid_t
    let appName: String

    var id: String { ref.key }

    init(ref: ItemRef, element: AXUIElement, frame: CGRect, pid: pid_t, appName: String) {
        self.ref = ref
        self.element = element
        self.frame = frame
        self.pid = pid
        self.appName = appName
    }
}

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let s = attr(el, name) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = attr(el, kAXChildrenAttribute) as? [AnyObject] else { return [] }
        return v.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        }
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

enum MenuBarScanner {
    /// Çalışan uygulamaların menü çubuğu öğelerini (AXExtrasMenuBar) toplar.
    /// Ana iş parçacığı dışında çağrılabilir.
    static func scan(onlyBundleID: String? = nil) -> [MenuBarItem] {
        guard AX.isTrusted else { return [] }
        let myPID = getpid()
        var result: [MenuBarItem] = []

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != myPID, pid > 0, !app.isTerminated else { continue }
            let bundleID = app.bundleIdentifier ?? app.executableURL?.lastPathComponent ?? "pid.\(pid)"
            if let only = onlyBundleID, only != bundleID { continue }

            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let bar = AX.element(axApp, "AXExtrasMenuBar") else { continue }
            AXUIElementSetMessagingTimeout(bar, 0.25)
            let appName = app.localizedName ?? bundleID

            var seenIDs: [String: Int] = [:]
            for (index, child) in AX.children(bar).enumerated() {
                guard let frame = AX.frame(child), frame.width > 1, frame.height > 1 else { continue }
                let identifier = AX.string(child, kAXIdentifierAttribute)
                let desc = AX.string(child, kAXDescriptionAttribute)
                let title = AX.string(child, kAXTitleAttribute)
                let help = AX.string(child, kAXHelpAttribute)

                var axID: String
                if let identifier { axID = "id:" + identifier }
                else if let desc { axID = "d:" + desc }
                else { axID = "#\(index)" }
                // Aynı uygulamada aynı kimliğe sahip iki öğe tek anahtara çökmesin.
                let dup = seenIDs[axID, default: 0]
                seenIDs[axID] = dup + 1
                if dup > 0 { axID += "#\(dup)" }

                let label = [desc, title, help].compactMap { $0 }.first { $0 != appName }
                let displayName = label.map { "\(appName) – \($0)" } ?? appName

                let ref = ItemRef(bundleID: bundleID, axID: axID, index: index, displayName: displayName)
                result.append(MenuBarItem(ref: ref, element: child, frame: frame, pid: pid, appName: appName))
            }
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Kayıtlı bir referansı canlı öğelerle eşleştirir: önce tam anahtar, sonra aynı uygulamada sıra.
    static func find(_ ref: ItemRef, in items: [MenuBarItem]) -> MenuBarItem? {
        if let exact = items.first(where: { $0.ref.key == ref.key }) { return exact }
        // Kararlı AXIdentifier'ı olan bir öğe yoksa başka bir öğeyle eşleştirme.
        if ref.axID.hasPrefix("id:") { return nil }
        // Açıklama tabanlı ("d:") kimlikler değişebilir; yalnızca aynı türdeki öğelerle yedek eşleştir.
        let kind: (String) -> String = { $0.hasPrefix("d:") ? "d" : ($0.hasPrefix("#") ? "#" : "id") }
        let sameApp = items.filter { $0.ref.bundleID == ref.bundleID && kind($0.ref.axID) == kind(ref.axID) }
        if sameApp.count == 1 { return sameApp[0] }
        return sameApp.first { $0.ref.index == ref.index }
    }

    /// Bir grup listesindeki tüm referansları canlı öğelere eşleştirir (bir öğe yalnızca bir kez eşleşir).
    static func match(refs: [ItemRef], in items: [MenuBarItem]) -> [String: MenuBarItem] {
        var out: [String: MenuBarItem] = [:]
        var used = Set<String>()
        // Önce tam eşleşmeler, sonra yedekler — bir yedeğin başka bir referansın tam eşini çalmaması için.
        for ref in refs {
            if let m = items.first(where: { $0.ref.key == ref.key }) {
                out[ref.key] = m
                used.insert(m.id)
            }
        }
        for ref in refs where out[ref.key] == nil {
            let candidates = items.filter { !used.contains($0.id) }
            if let m = find(ref, in: candidates), m.ref.bundleID == ref.bundleID {
                out[ref.key] = m
                used.insert(m.id)
            }
        }
        return out
    }

    /// Öğeye tıklar: önce AXPress, olmazsa gerçek fare tıklaması.
    @discardableResult
    static func press(_ item: MenuBarItem) -> Bool {
        // Menü açan öğelerde AXPress, menü kapanana dek bloklanır ve .cannotComplete döner:
        // bu bir hata değil, eylem iletilmiştir. Yalnızca gerçekten desteklenmiyorsa yedeğe geç.
        AXUIElementSetMessagingTimeout(item.element, 1.0)
        let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        Log.write("AXPress sonucu: \(r.rawValue)")
        if r == .success || r == .cannotComplete { return true }
        if r == .actionUnsupported {
            let r2 = AXUIElementPerformAction(item.element, "AXShowMenu" as CFString)
            if r2 == .success || r2 == .cannotComplete { return true }
        }
        let fresh = AX.frame(item.element) ?? item.frame
        guard isOnScreen(fresh) else { return false }
        EventPoster.click(at: CGPoint(x: fresh.midX, y: fresh.midY))
        return true
    }

    static func isOnScreen(_ rect: CGRect) -> Bool {
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 0, nil, &count)
        return count > 0
    }
}

// MARK: - Sentetik olaylar

enum EventPoster {
    private static let commandKey: CGKeyCode = 0x37

    static var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func click(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let original = cursorLocation
        post(src, .mouseMoved, point, [])
        usleep(20_000)
        post(src, .leftMouseDown, point, [])
        usleep(30_000)
        post(src, .leftMouseUp, point, [])
        usleep(20_000)
        CGWarpMouseCursorPosition(original)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// ⌘-sürükleme ile menü çubuğu öğesini taşır. Ana iş parçacığında ÇAĞIRMAYIN (bekleme içerir).
    static func commandDrag(from start: CGPoint, to end: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let original = cursorLocation
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        usleep(30_000)

        post(src, .mouseMoved, start, .maskCommand)
        usleep(40_000)
        post(src, .leftMouseDown, start, .maskCommand)
        usleep(120_000)
        // Sürüklemeyi başlatmak için önce birkaç piksellik "kaldırma" hareketi.
        let dir: CGFloat = end.x < start.x ? -1 : 1
        for i in 1...3 {
            post(src, .leftMouseDragged, CGPoint(x: start.x + dir * CGFloat(i) * 2, y: start.y), .maskCommand)
            usleep(50_000)
        }

        // macOS diğer öğeleri sürükleme sırasında canlı kaydırır; çok hızlı bırakılırsa öğe
        // hedefe ulaşmadan yerleşir. Yavaş ilerle ve bırakmadan önce hedefte bekle.
        let steps = max(20, Int(abs(end.x - start.x) / 5))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(src, .leftMouseDragged, p, .maskCommand)
            usleep(16_000)
        }
        for dx in [-1.0, 1.0, 0.0] {
            usleep(90_000)
            post(src, .leftMouseDragged, CGPoint(x: end.x + dx, y: end.y), .maskCommand)
        }
        usleep(250_000)
        post(src, .leftMouseUp, end, .maskCommand)
        usleep(60_000)

        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)
        cmdUp?.flags = []
        cmdUp?.post(tap: .cghidEventTap)
        usleep(60_000)
    }

    private static func post(_ src: CGEventSource?, _ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - Pencere listesi yardımcıları

enum WindowList {
    /// Verilen sürecin açık bir menüsü / açılır penceresi var mı?
    /// `baseline`: öğeye basılmadan önce zaten açık olan pencereler (kalıcı paneller vb.) yok sayılır.
    static func hasPopup(pid: pid_t, ignoring baseline: Set<Int> = []) -> Bool {
        windowNumbers(pid: pid).subtracting(baseline).isEmpty == false
    }

    /// Sürecin menü/açılır pencere olabilecek (katman ≥ 3, menü çubuğu öğesi olmayan) pencereleri.
    static func windowNumbers(pid: pid_t) -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let barHeight = Screen.menuBarHeight + 2
        var out = Set<Int>()
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, owner == Int(pid) else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= 3, layer != 24 else { continue } // 24 = ana menü
            if let b = w[kCGWindowBounds as String] as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
                // Menü çubuğu öğesinin kendi penceresi (herhangi bir ekranda).
                if layer == 25, r.height <= barHeight { continue }
                if r.width < 2 || r.height < 2 { continue }
            }
            out.insert(w[kCGWindowNumber as String] as? Int ?? out.count)
        }
        return out
    }
}

enum Screen {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static var menuBarHeight: CGFloat {
        guard let s = NSScreen.screens.first else { return 24 }
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 10 ? h : max(24, NSStatusBar.system.thickness)
    }

    /// Cocoa (sol alt) dikdörtgeni CoreGraphics (sol üst) dikdörtgenine çevirir.
    static func cgRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// CG koordinatlarında noktayı içeren ekranın çerçevesi.
    static func displayRect(containing p: CGPoint) -> CGRect? {
        NSScreen.screens.map { cgRect(fromCocoa: $0.frame) }.first { $0.contains(p) }
    }

    static func isMouseInMenuBar() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) else { return false }
        return loc.y >= screen.frame.maxY - max(Screen.menuBarHeight, 24) - 2
    }
}
