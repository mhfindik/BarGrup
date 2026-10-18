import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            statusBar?.sync(groups: config.groups)
            statusBar?.refreshToggle()
            if config.hidingEnabled != oldValue.hidingEnabled {
                statusBar?.setHidden(config.hidingEnabled)
            }
        }
    }

    /// Son taramada bulunan canlı öğeler.
    @Published private(set) var scanned: [MenuBarItem] = [] {
        didSet { recomputeHiddenKeys() }
    }
    /// Tarama anında ayracın solunda (gizli bölümde) olan öğelerin anahtarları.
    @Published private(set) var hiddenKeys: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var accessibilityGranted = AX.isTrusted
    @Published private(set) var isArranging = false
    @Published var arrangeReport: String?
    @Published var selectedGroupID: UUID?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var statusBar: StatusBarController?
    private var settingsWindow: NSWindow?
    private var saveWorkItem: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var rehideWatch: Timer?
    /// Bir öğeyi açmak için gizli bölüm geçici olarak gösterildi mi?
    private var tempRevealed = false
    private var isFixingOwnItems = false
    /// Grup üyelikleri değişti ama öğeler henüz yerleştirilmedi.
    private var membershipChanged = false
    private var settingsCloseObserver: NSObjectProtocol?

    init() {
        config = ConfigStore.load()
    }

    func start() {
        let bar = StatusBarController(model: self)
        statusBar = bar
        bar.setUp(groups: config.groups)
        bar.setHidden(config.hidingEnabled)

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }

        if !AX.isTrusted { AX.requestTrust() }
        if !config.didShowWelcome || config.groups.isEmpty {
            openSettings()
            config.didShowWelcome = true
        }
        rescan()
    }

    func flushSave() {
        saveWorkItem?.cancel()
        ConfigStore.save(config)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            ConfigStore.save(self.config)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func refreshPermissions() {
        let ax = AX.isTrusted
        if ax != accessibilityGranted {
            accessibilityGranted = ax
            if ax { rescan() }
        }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
    }

    // MARK: Gruplar

    func addGroup() {
        let n = config.groups.count
        var g = ItemGroup(name: "Grup \(n + 1)",
                          colorHex: Palette.presets[n % Palette.presets.count],
                          symbol: Palette.symbols[n % Palette.symbols.count])
        // Aynı ad olmasın.
        var k = n + 1
        while config.groups.contains(where: { $0.name == g.name }) { k += 1; g.name = "Grup \(k)" }
        config.groups.append(g)
        selectedGroupID = g.id
    }

    func removeGroup(_ id: UUID) {
        guard let idx = config.groups.firstIndex(where: { $0.id == id }) else { return }
        if !config.groups[idx].items.isEmpty { membershipChanged = true }
        config.groups.remove(at: idx)
        if selectedGroupID == id {
            selectedGroupID = config.groups.indices.contains(idx) ? config.groups[idx].id : config.groups.last?.id
        }
    }

    func moveGroups(from: IndexSet, to: Int) {
        config.groups.move(fromOffsets: from, toOffset: to)
    }

    func groupBinding(_ id: UUID) -> Binding<ItemGroup>? {
        guard let g = config.groups.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.config.groups.first(where: { $0.id == id }) ?? g },
            set: { [weak self] new in
                guard let self, let i = self.config.groups.firstIndex(where: { $0.id == id }) else { return }
                self.config.groups[i] = new
            })
    }

    /// Öğeyi gruba ekler; bir öğe yalnızca tek grupta bulunur.
    func add(_ ref: ItemRef, to groupID: UUID) {
        var groups = config.groups
        for i in groups.indices { groups[i].items.removeAll { $0.key == ref.key } }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[gi].items.append(ref)
        config.groups = groups
        membershipChanged = true
    }

    func remove(_ ref: ItemRef, from groupID: UUID) {
        guard let gi = config.groups.firstIndex(where: { $0.id == groupID }) else { return }
        config.groups[gi].items.removeAll { $0.key == ref.key }
        membershipChanged = true
    }

    func moveItems(in groupID: UUID, from: IndexSet, to: Int) {
        guard let gi = config.groups.firstIndex(where: { $0.id == groupID }) else { return }
        config.groups[gi].items.move(fromOffsets: from, toOffset: to)
    }

    func group(containing ref: ItemRef) -> ItemGroup? {
        config.groups.first { g in g.items.contains { $0.key == ref.key } }
    }

    // MARK: Tarama ve ikonlar

    func rescan() {
        guard AX.isTrusted else { scanned = []; return }
        guard !isScanning else { return }
        isScanning = true
        Task {
            let items = await Task.detached(priority: .userInitiated) { MenuBarScanner.scan() }.value
            self.scanned = items
            self.isScanning = false
            self.updateStoredRefs(with: items)
        }
    }

    /// Kayıtlı referansların görünen adlarını ve sıra numaralarını canlı öğelerle günceller.
    private func updateStoredRefs(with items: [MenuBarItem]) {
        var groups = config.groups
        var changed = false
        var allKeys = Set(groups.flatMap { $0.items.map(\.key) })
        for gi in groups.indices {
            let matches = MenuBarScanner.match(refs: groups[gi].items, in: items)
            for ii in groups[gi].items.indices {
                let ref = groups[gi].items[ii]
                guard let live = matches[ref.key] else { continue }
                if live.ref.key == ref.key {
                    if live.ref.displayName != ref.displayName || live.ref.index != ref.index {
                        groups[gi].items[ii].displayName = live.ref.displayName
                        groups[gi].items[ii].index = live.ref.index
                        changed = true
                    }
                } else if !allKeys.contains(live.ref.key) {
                    // Kimliği (ör. dinamik açıklama) değişmiş öğe: kaydı canlı anahtara taşı.
                    allKeys.remove(ref.key)
                    allKeys.insert(live.ref.key)
                    groups[gi].items[ii] = live.ref
                    changed = true
                }
            }
        }
        if changed { config.groups = groups }
    }

    func icon(for ref: ItemRef) -> NSImage {
        Icons.itemIcon(for: ref)
    }

    /// Ayarlarda gösterilen öğeler: yalnızca menü çubuğunda gerçekten duran öğeler, soldan sağa sırayla.
    var catalog: [ItemRef] {
        let barHeight = Screen.menuBarHeight + 6
        var seen = Set<String>()
        return scanned
            .filter { $0.frame.height <= barHeight && $0.frame.width > 1 }
            .filter { seen.insert($0.ref.key).inserted }
            .map(\.ref)
    }

    enum ItemState { case visible, hidden, missing }

    func state(of ref: ItemRef) -> ItemState {
        guard let live = MenuBarScanner.find(ref, in: scanned) else { return .missing }
        return hiddenKeys.contains(live.id) ? .hidden : .visible
    }

    private func recomputeHiddenKeys() {
        guard let hider = statusBar?.hiderFrame else { hiddenKeys = []; return }
        hiddenKeys = Set(scanned.filter { $0.frame.midX < hider.minX }.map(\.id))
    }

    /// Settings'te gösterilen bir öğe, bu grubun bir kaydıyla (yedek eşleşmeyle bile) eşleşiyor mu?
    func liveKeysMatched(by refs: [ItemRef]) -> Set<String> {
        Set(MenuBarScanner.match(refs: refs, in: scanned).values.map(\.ref.key))
    }

    // MARK: Açma

    /// Gruptaki bir öğeyi açar (gerekirse gizli bölümü geçici olarak gösterir).
    func open(_ ref: ItemRef) {
        guard AX.isTrusted else {
            AX.requestTrust()
            openSettings()
            return
        }
        guard let bar = statusBar, !isArranging else { return }
        let needsReveal = config.revealWhenOpening && (bar.isHidden || tempRevealed)
        if bar.isHidden && config.revealWhenOpening {
            bar.setHidden(false)
            tempRevealed = true
        }
        rehideWatch?.invalidate()
        let wasJustRevealed = needsReveal && bar.isHidden == false

        DispatchQueue.main.asyncAfter(deadline: .now() + (wasJustRevealed ? 0.35 : 0.05)) { [weak self] in
            guard let self else { return }
            Task {
                let items = await Task.detached(priority: .userInitiated) { MenuBarScanner.scan(onlyBundleID: ref.bundleID) }.value
                guard let item = MenuBarScanner.find(ref, in: items) else {
                    Log.write("aç: bulunamadı \(ref.key) (uygulamada \(items.count) öğe: \(items.map(\.ref.key)))")
                    NSSound.beep()
                    if needsReveal, self.tempRevealed { self.endTemporaryReveal(); self.statusBar?.setHidden(true) }
                    return
                }
                let baseline = WindowList.windowNumbers(pid: item.pid)
                // press(), menü açık kaldıkça bloklanabilir; izlemeyi ondan önce başlat.
                if needsReveal { self.watchAndRehide(pid: item.pid, baseline: baseline) }
                Log.write("aç: \(ref.key) → \(item.ref.key) çerçeve=\(item.frame) gösterildi=\(wasJustRevealed)")
                let pressed = await Task.detached(priority: .userInitiated) { MenuBarScanner.press(item) }.value
                Log.write("aç: bas sonucu=\(pressed)")
                if !pressed { NSSound.beep() }
            }
        }
    }

    /// Açılan menü/pencere kapanınca gizli bölümü tekrar gizler.
    /// Geçici gösterimi bitmiş say (elle gizle/göster ya da yerleştirme başladığında).
    func endTemporaryReveal() {
        tempRevealed = false
        rehideWatch?.invalidate()
        rehideWatch = nil
    }

    private func watchAndRehide(pid: pid_t, baseline: Set<Int>) {
        rehideWatch?.invalidate()
        var quietTicks = 0
        var elapsed = 0.0
        let interval = 0.4
        // Menü açılırken ilk anda pencere görünmeyebilir: kısa bir ön bekleme.
        var grace = 3
        rehideWatch = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let bar = self.statusBar else { timer.invalidate(); return }
                elapsed += interval
                if self.isArranging { return }
                if !self.config.hidingEnabled || bar.isHidden || !self.tempRevealed {
                    timer.invalidate(); self.tempRevealed = false; return
                }
                if grace > 0 { grace -= 1; return }
                let busy = WindowList.hasPopup(pid: pid, ignoring: baseline) || Screen.isMouseInMenuBar()
                quietTicks = busy ? 0 : quietTicks + 1
                if quietTicks >= 2 || elapsed > 180 {
                    timer.invalidate()
                    self.tempRevealed = false
                    bar.setHidden(true)
                }
            }
        }
    }

    // MARK: Yerleştirme (⌘-sürükle)

    func startArrange() {
        guard !isArranging, !isFixingOwnItems else { return }
        guard AX.isTrusted else {
            AX.requestTrust()
            arrangeReport = "Öğeleri taşımak için Erişilebilirlik izni gerekli."
            openSettings()
            return
        }
        isArranging = true
        Task { await arrange() }
    }

    /// Gruplanmış öğeleri ayracın soluna (gizli), diğerlerini sağına (görünür) taşır.
    func arrange() async {
        guard let bar = statusBar else { isArranging = false; return }
        isArranging = true
        arrangeReport = "Yerleştiriliyor… Lütfen fareyi oynatmayın."
        endTemporaryReveal()
        bar.panel.close()
        bar.setHidden(false)
        try? await Task.sleep(nanoseconds: 600_000_000)

        var attempts: [String: Int] = [:]
        var failed = Set<String>()
        // Her sürükleme öğeyi biraz ilerletebilir; yalnızca ilerleme durunca vazgeç.
        var lastX: [String: CGFloat] = [:]
        var stalls: [String: Int] = [:]
        var moved = 0
        let refs = config.groups.flatMap(\.items)

        for _ in 0..<80 {
            // Bu sırada bir şey ayracı genişlettiyse tekrar daralt.
            if bar.isHidden {
                bar.setHidden(false)
                try? await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            let items = await Task.detached(priority: .userInitiated) { MenuBarScanner.scan() }.value
            guard let hider = bar.hiderFrame,
                  let hiderDisplay = Screen.displayRect(containing: CGPoint(x: hider.maxX - 1, y: hider.midY)) else { break }
            let grouped = Set(MenuBarScanner.match(refs: refs, in: items).values.map(\.id))

            var job: (from: CGPoint, to: CGPoint, key: String)?

            // 1) Kendi öğelerimiz ayracın sağında olmalı.
            if let own = bar.ownItemFrames.first(where: {
                $0.midX < hider.minX && MenuBarScanner.isOnScreen($0) && attempts["own@\(Int($0.minX))", default: 0] < 2
            }) {
                job = (CGPoint(x: own.midX, y: own.midY), CGPoint(x: hider.maxX - 2, y: hider.midY), "own@\(Int(own.minX))")
            }
            // 2) Başka uygulamaların öğeleri.
            if job == nil {
                for item in items where !failed.contains(item.id) {
                    // Yalnızca ayraçla aynı ekrandaki menü çubuğunda görünen öğeler sürüklenebilir.
                    guard hiderDisplay.contains(CGPoint(x: item.frame.midX, y: item.frame.midY)) else { continue }
                    let shouldHide = grouped.contains(item.id)
                    let isLeft = item.frame.midX < hider.minX
                    guard shouldHide != isLeft else { continue }
                    // Gruplanmamış Denetim Merkezi öğeleri (canlı etkinlikler vb.) taşınamaz; dokunma.
                    if !shouldHide && Icons.isSystemItem(item.ref) { continue }
                    if let prev = lastX[item.id], abs(prev - item.frame.midX) < 4 {
                        stalls[item.id, default: 0] += 1
                    }
                    if stalls[item.id, default: 0] >= 3 || attempts[item.id, default: 0] >= 6 {
                        failed.insert(item.id); continue
                    }
                    lastX[item.id] = item.frame.midX
                    // Takılırsa her denemede ayracın biraz daha ötesine bırak (komşunun yakın yarısına).
                    let overshoot: [CGFloat] = [2, -8, -18, -30]
                    let o = overshoot[min(stalls[item.id, default: 0], overshoot.count - 1)]
                    let target = shouldHide ? CGPoint(x: hider.minX + o, y: hider.midY)
                                            : CGPoint(x: hider.maxX - o, y: hider.midY)
                    job = (CGPoint(x: item.frame.midX, y: item.frame.midY), target, item.id)
                    break
                }
            }
            guard let job else { break }
            Log.write("yerleştir: \(job.key) \(job.from) → \(job.to) ayraç=\(hider)")
            attempts[job.key, default: 0] += 1
            await Task.detached(priority: .userInitiated) { EventPoster.commandDrag(from: job.from, to: job.to) }.value
            moved += 1
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let finalItems = await Task.detached(priority: .userInitiated) { MenuBarScanner.scan() }.value
        scanned = finalItems

        // Sonuç raporu
        var stuck: [String] = []
        if let hider = bar.hiderFrame {
            let grouped = Set(MenuBarScanner.match(refs: refs, in: finalItems).values.map(\.id))
            for item in finalItems where (grouped.contains(item.id)) != (item.frame.midX < hider.minX) {
                if !grouped.contains(item.id) && Icons.isSystemItem(item.ref) { continue }
                stuck.append(item.ref.displayName)
            }
        }
        isArranging = false
        Log.write("yerleştir bitti: taşıma=\(moved) kalan=\(stuck)")
        if stuck.isEmpty {
            arrangeReport = moved == 0 ? "Her şey zaten yerinde." : "Tamamlandı: \(moved) taşıma yapıldı."
        } else {
            arrangeReport = "Taşınamayan öğeler (⌘ ile elle sürükleyin): " + stuck.joined(separator: ", ")
        }
        if config.hidingEnabled { bar.setHidden(true) }
    }

    /// Yeni eklenen bir grup simgesi gizli bölüme düştüyse onu ayracın sağına taşır.
    func fixOwnItemsIfNeeded() {
        guard AX.isTrusted, !isArranging, !isFixingOwnItems, let bar = statusBar, let hider = bar.hiderFrame else { return }
        let misplaced = bar.ownItemFrames.filter { $0.midX < hider.minX }
        guard !misplaced.isEmpty else { return }
        let wasHidden = bar.isHidden
        isFixingOwnItems = true
        Task {
            defer { self.isFixingOwnItems = false }
            if wasHidden {
                bar.setHidden(false)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            for _ in 0..<6 {
                if self.isArranging { break }
                guard let h = bar.hiderFrame,
                      let f = bar.ownItemFrames.first(where: { $0.midX < h.minX && MenuBarScanner.isOnScreen($0) }) else { break }
                await Task.detached { EventPoster.commandDrag(from: CGPoint(x: f.midX, y: f.midY), to: CGPoint(x: h.maxX - 2, y: h.midY)) }.value
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if wasHidden && self.config.hidingEnabled && !self.isArranging { bar.setHidden(true) }
        }
    }

    // MARK: Ayarlar penceresi

    func openSettings(selecting id: UUID? = nil) {
        if let id { selectedGroupID = id }
        else if selectedGroupID == nil { selectedGroupID = config.groups.first?.id }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(self))
            let w = NSWindow(contentViewController: host)
            w.title = "BarGrup Ayarları"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 900, height: 600))
            w.minSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("BarGrupSettings")
            settingsWindow = w
            // Ayarlar kapanınca, gruplar değiştiyse öğeleri otomatik yerleştir (gizle/göster).
            settingsCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.membershipChanged, AX.isTrusted else { return }
                    self.membershipChanged = false
                    Log.write("ayarlar kapandı: otomatik yerleştirme")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.startArrange()
                    }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        rescan()
    }

    // MARK: Genel

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            arrangeReport = "Oturum açılışında başlatma ayarlanamadı: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
