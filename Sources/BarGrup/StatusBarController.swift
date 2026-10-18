import AppKit
import SwiftUI

/// Uygulamanın kendi menü çubuğu öğelerini yönetir:
///  [gizli bölüm …][ayraç][grup 1][grup 2]…[aç/kapa]
/// Ayraç genişletildiğinde (10 000 pt) solundaki her şey ekran dışına itilir.
@MainActor
final class StatusBarController: NSObject {
    static let hiderName = "BarGrup.hider"
    static let toggleName = "BarGrup.toggle"
    static func groupName(_ id: UUID) -> String { "BarGrup.group.\(id.uuidString)" }
    static func positionKey(_ autosaveName: String) -> String { "NSStatusItem Preferred Position \(autosaveName)" }

    private static let expandedLength: CGFloat = 10_000
    private static let collapsedLength: CGFloat = 12

    weak var model: AppModel?

    private var toggleItem: NSStatusItem!
    private var hiderItem: NSStatusItem!
    private var groupItems: [UUID: NSStatusItem] = [:]

    private(set) var isHidden = false
    private var rehideTimer: Timer?
    private var idleSeconds = 0

    let panel = GroupPanelController()

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Öğeleri oluşturur. macOS yeni öğeleri en sola eklediğinden sıra: aç/kapa → gruplar (sondan) → ayraç.
    func setUp(groups: [ItemGroup]) {
        // İlk açılışta kendi öğelerimiz en sola (çentiğin arkasına) düşmesin: aç/kapa ve grupları sağa yerleştir.
        // Ayraç bilerek tohumlanmaz; en solda kalır ki “Yerleştir” çalışana dek hiçbir şey gizlenmesin.
        let d = UserDefaults.standard
        if d.object(forKey: Self.positionKey(Self.toggleName)) == nil {
            d.set(1.0, forKey: Self.positionKey(Self.toggleName))
            for (i, g) in groups.enumerated() where d.object(forKey: Self.positionKey(Self.groupName(g.id))) == nil {
                d.set(Double(2 + i), forKey: Self.positionKey(Self.groupName(g.id)))
            }
        }
        toggleItem = makeItem(name: Self.toggleName, length: NSStatusItem.variableLength)
        if let b = toggleItem.button {
            b.target = self
            b.action = #selector(toggleClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "BarGrup — gizli öğeleri göster/gizle (sağ tık: menü)"
        }
        for g in groups.reversed() { createGroupItem(g) }

        hiderItem = makeItem(name: Self.hiderName, length: Self.collapsedLength)
        if let b = hiderItem.button {
            b.target = self
            b.action = #selector(hiderClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "BarGrup ayracı — solundaki öğeler gizlenir. ⌘ ile sürükleyerek öğeleri taşıyabilirsiniz."
        }
        updateHiderAppearance()
        updateToggleAppearance()
        scheduleGroupPlacement(groups)
    }

    private func makeItem(name: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        item.behavior = []
        item.isVisible = true
        return item
    }

    // MARK: Gruplar

    func sync(groups: [ItemGroup]) {
        let ids = Set(groups.map(\.id))
        for (id, item) in groupItems where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            groupItems[id] = nil
            UserDefaults.standard.removeObject(forKey: Self.positionKey(Self.groupName(id)))
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(Self.groupName(id))")
            if panel.groupID == id { panel.close() }
        }
        var added = false
        for g in groups {
            if groupItems[g.id] == nil { createGroupItem(g); added = true }
            updateGroupAppearance(g)
        }
        if added || groups.map(\.id) != placedOrder { scheduleGroupPlacement(groups) }
        if let open = panel.groupID, let g = groups.first(where: { $0.id == open }) {
            panel.refresh(group: g)
        }
    }

    private func createGroupItem(_ group: ItemGroup) {
        let item = makeItem(name: Self.groupName(group.id), length: NSStatusItem.variableLength)
        if let b = item.button {
            b.target = self
            b.action = #selector(groupClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.identifier = NSUserInterfaceItemIdentifier(group.id.uuidString)
        }
        groupItems[group.id] = item
        updateGroupAppearance(group)
    }

    // MARK: Grup simgelerinin yerleşimi

    /// Grup simgelerinin son doğrulandığı sıra.
    private var placedOrder: [UUID] = []
    private var placementWork: DispatchWorkItem?
    private var placementAttempts = 0

    /// macOS konumları yerleşimden sonra yazar; kısa bir gecikmeyle kontrol et.
    private func scheduleGroupPlacement(_ groups: [ItemGroup]) {
        placementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                self.ensureGroupPlacement(model.config.groups)
            }
        }
        placementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// "NSStatusItem Preferred Position" = öğenin ekranın sağ kenarına uzaklığı (küçük değer = daha sağda).
    /// Grup simgeleri ayracın hemen sağında, listedeki sırayla (soldan sağa) durmalı. Değilse
    /// simgeleri kaldırıp konumlarını yazarak yeniden oluştur — ⌘-sürüklemeye gerek kalmadan.
    private func ensureGroupPlacement(_ groups: [ItemGroup]) {
        guard !groups.isEmpty, let hiderItem else { placedOrder = groups.map(\.id); return }
        let d = UserDefaults.standard
        let hiderPos: Double
        if let stored = d.object(forKey: Self.positionKey(Self.hiderName)) as? Double {
            hiderPos = stored
        } else if let w = hiderItem.button?.window, let screen = w.screen ?? NSScreen.screens.first {
            // Henüz kaydedilmemiş: gerçek çerçeveden tahmin et.
            hiderPos = Double(screen.frame.maxX - w.frame.minX)
        } else {
            return
        }

        let positions = groups.map { d.object(forKey: Self.positionKey(Self.groupName($0.id))) as? Double }
        var ok = positions.allSatisfy { ($0 ?? .infinity) < hiderPos }
        if ok {
            let vals = positions.compactMap { $0 }
            ok = zip(vals, vals.dropFirst()).allSatisfy { $0 > $1 }
        }
        // Gerçek çerçeveler: bir grup simgesi ayracın solundaysa yanlış yerdedir.
        if ok, let hf = hiderFrame {
            for g in groups {
                if let w = groupItems[g.id]?.button?.window, Screen.cgRect(fromCocoa: w.frame).midX < hf.minX { ok = false }
            }
        }
        Log.write("çerçeveler: ayraç=\(hiderFrame.map { "\($0)" } ?? "nil") kendi=\(ownItemFrames)")
        Log.write("yerleşim: ayraç=\(hiderPos) gruplar=\(positions.map { $0.map { String(Int($0)) } ?? "-" }) uygun=\(ok)")
        if ok { placedOrder = groups.map(\.id); placementAttempts = 0; return }
        guard placementAttempts < 3 else { Log.write("yerleşim: deneme sınırı aşıldı"); return }
        placementAttempts += 1

        for g in groups {
            if let item = groupItems[g.id] { NSStatusBar.system.removeStatusItem(item) }
            groupItems[g.id] = nil
        }
        // removeStatusItem kayıtlı konumu silebilir; konumları kaldırmadan SONRA yaz.
        for (i, g) in groups.enumerated() {
            d.set(hiderPos - 1 - Double(i), forKey: Self.positionKey(Self.groupName(g.id)))
        }
        for g in groups { createGroupItem(g) }
        if let open = panel.groupID, groupItems[open] != nil { panel.close() }
        scheduleGroupPlacement(groups)
    }

    private func updateGroupAppearance(_ g: ItemGroup) {
        guard let b = groupItems[g.id]?.button else { return }
        b.image = Icons.groupIcon(colorHex: g.colorHex, symbol: g.symbol)
        b.imagePosition = .imageOnly
        b.toolTip = "\(g.name) — \(g.items.count) öğe"
        b.setAccessibilityLabel("BarGrup grubu: \(g.name)")
    }

    // MARK: Gizleme

    func setHidden(_ hidden: Bool, manual: Bool = false) {
        if manual { model?.endTemporaryReveal() }
        isHidden = hidden
        hiderItem.length = hidden ? Self.expandedLength : Self.collapsedLength
        updateHiderAppearance()
        updateToggleAppearance()
        rehideTimer?.invalidate()
        rehideTimer = nil
        if !hidden, manual { startAutoRehide() }
    }

    private func startAutoRehide() {
        guard let secs = model?.config.autoRehideSeconds, secs > 0, model?.config.hidingEnabled == true else { return }
        idleSeconds = 0
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Screen.isMouseInMenuBar() || NSMenu.isAnyMenuOpen { self.idleSeconds = 0; return }
                self.idleSeconds += 1
                if self.idleSeconds >= secs { self.setHidden(true) }
            }
        }
    }

    private func updateHiderAppearance() {
        guard let b = hiderItem?.button else { return }
        if isHidden {
            b.image = nil
            b.title = ""
        } else {
            let img = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Ayraç")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            img?.isTemplate = true
            b.image = img
            b.appearsDisabled = true
        }
    }

    private func updateToggleAppearance() {
        guard let b = toggleItem?.button else { return }
        let hidingActive = model?.config.hidingEnabled ?? true
        let name = !hidingActive ? "square.grid.2x2" : (isHidden ? "chevron.left" : "chevron.right")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "BarGrup")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        img?.isTemplate = true
        b.image = img
    }

    func refreshToggle() { updateToggleAppearance() }

    // MARK: Konumlar

    /// Ayraç penceresinin CG koordinatlarındaki çerçevesi.
    var hiderFrame: CGRect? {
        guard let w = hiderItem?.button?.window else { return nil }
        return Screen.cgRect(fromCocoa: w.frame)
    }

    /// Ayracın sağında durması gereken kendi öğelerimizin çerçeveleri.
    var ownItemFrames: [CGRect] {
        var out: [CGRect] = []
        if let w = toggleItem?.button?.window { out.append(Screen.cgRect(fromCocoa: w.frame)) }
        for item in groupItems.values {
            if let w = item.button?.window { out.append(Screen.cgRect(fromCocoa: w.frame)) }
        }
        return out
    }

    func buttonWindowFrame(for groupID: UUID) -> NSRect? {
        groupItems[groupID]?.button?.window?.frame
    }

    // MARK: Eylemler

    @objc private func toggleClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu(from: toggleItem, group: nil)
            return
        }
        guard model?.config.hidingEnabled == true else {
            model?.openSettings()
            return
        }
        panel.close()
        guard model?.isArranging != true else { NSSound.beep(); return }
        setHidden(!isHidden, manual: true)
    }

    @objc private func hiderClicked(_ sender: NSStatusBarButton) {
        panel.close()
        // Gizliyken ayraç menü çubuğunun boş alanını kaplar; sol tıklar orada yok sayılır.
        if isHidden, NSApp.currentEvent?.type != .rightMouseUp { return }
        showMenu(from: hiderItem, group: nil)
    }

    @objc private func groupClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        Log.write("grup tıklandı: id=\(sender.identifier?.rawValue ?? "nil") olay=\(event?.type.rawValue ?? 0) pencere=\(sender.window.map { "\($0.frame)" } ?? "nil")")
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let group = model?.config.groups.first(where: { $0.id == id }) else {
            Log.write("grup tıklandı: grup bulunamadı")
            return
        }
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu(from: groupItems[id], group: group)
            return
        }
        if panel.groupID == id, panel.isVisible {
            panel.close()
            return
        }
        guard let model else { return }
        panel.show(group: group, model: model, below: anchorFrame(for: sender))
        Log.write("panel gösterildi: \(group.name) görünür=\(panel.isVisible)")
    }

    /// Düğmenin ekran çerçevesi; macOS 26'da pencere bilgisi gelmezse tıklama konumundan tahmin et.
    private func anchorFrame(for button: NSStatusBarButton) -> NSRect {
        if let w = button.window, w.frame.width > 1, NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) {
            return w.frame
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens[0]
        let barHeight = max(Screen.menuBarHeight, 24)
        return NSRect(x: mouse.x - 12, y: screen.frame.maxY - barHeight, width: 24, height: barHeight)
    }

    private func showMenu(from item: NSStatusItem?, group: ItemGroup?) {
        guard let item else { return }
        panel.close()
        let menu = NSMenu()
        if let group {
            let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let edit = NSMenuItem(title: "Bu grubu düzenle…", action: #selector(menuEditGroup(_:)), keyEquivalent: "")
            edit.representedObject = group.id.uuidString
            edit.target = self
            menu.addItem(edit)
            menu.addItem(.separator())
        }
        if model?.config.hidingEnabled == true {
            let t = NSMenuItem(title: isHidden ? "Gizli öğeleri göster" : "Gizli öğeleri gizle", action: #selector(menuToggleHidden), keyEquivalent: "")
            t.target = self
            menu.addItem(t)
        }
        let arrange = NSMenuItem(title: "Öğeleri yerleştir", action: #selector(menuArrange), keyEquivalent: "")
        arrange.target = self
        menu.addItem(arrange)
        let settings = NSMenuItem(title: "Ayarlar…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "BarGrup'tan çık", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func menuEditGroup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        model?.openSettings(selecting: id)
    }

    @objc private func menuToggleHidden() {
        guard model?.isArranging != true else { NSSound.beep(); return }
        setHidden(!isHidden, manual: true)
    }
    @objc private func menuArrange() { model?.startArrange() }
    @objc private func menuSettings() { model?.openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

extension NSMenu {
    /// Başka bir uygulamanın menüsü açık mı? (CGWindow katman 101 = açılır menü)
    static var isAnyMenuOpen: Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == 101 }
    }
}
