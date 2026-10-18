import AppKit
import SwiftUI

/// Grup simgesine tıklanınca altında açılan, gruptaki öğeleri gösteren panel.
final class GroupPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { orderOut(nil) }
    }
}

@MainActor
final class GroupPanelController {
    private var window: GroupPanelWindow?
    private var hosting: NSHostingView<GroupPanelView>?
    private var monitors: [Any] = []
    private weak var model: AppModel?
    private var anchor: NSRect = .zero

    private(set) var groupID: UUID?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(group: ItemGroup, model: AppModel, below buttonFrame: NSRect) {
        self.model = model
        groupID = group.id
        anchor = buttonFrame

        let view = makeView(group)
        if window == nil {
            let w = GroupPanelWindow(contentRect: .zero,
                                     styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                     backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .popUpMenu
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .utilityWindow

            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true

            let host = NSHostingView(rootView: view)
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            w.contentView = effect
            w.onCancel = { [weak self] in self?.close() }
            window = w
            hosting = host
        } else {
            hosting?.rootView = view
        }
        layout()
        window?.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func refresh(group: ItemGroup) {
        guard isVisible, group.id == groupID else { return }
        hosting?.rootView = makeView(group)
        layout()
    }

    func close() {
        window?.orderOut(nil)
        groupID = nil
        removeMonitors()
    }

    private func makeView(_ group: ItemGroup) -> GroupPanelView {
        GroupPanelView(group: group,
                       showLabels: model?.config.showLabels ?? true,
                       iconProvider: { [weak model] ref in model?.icon(for: ref) ?? Icons.appIcon(bundleID: ref.bundleID) },
                       onPick: { [weak self] ref in
                           guard let self else { return }
                           let m = self.model
                           self.close()
                           m?.open(ref)
                       },
                       onEdit: { [weak self] in
                           guard let self else { return }
                           let m = self.model
                           self.close()
                           m?.openSettings(selecting: group.id)
                       })
    }

    private func layout() {
        guard let window, let hosting else { return }
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = anchor.minY - size.height - 6
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // Kendi pencerelerimize (ör. Ayarlar) yapılan tıklamalar global monitöre düşmez.
        // Panelin kendisi ve menü çubuğu öğelerimiz (kendi tıklama işleyicileri var) hariç kapat.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let w = self.window else { return }
                if event.window === w { return }
                if let cls = event.window?.className, cls.contains("StatusBar") { return }
                self.close()
            }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

struct GroupPanelView: View {
    let group: ItemGroup
    let showLabels: Bool
    let iconProvider: (ItemRef) -> NSImage
    let onPick: (ItemRef) -> Void
    let onEdit: () -> Void

    private var columns: [GridItem] {
        let count = max(1, min(group.items.count, 6))
        return Array(repeating: GridItem(.fixed(showLabels ? 72 : 40), spacing: 4), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: Icons.groupIcon(colorHex: group.colorHex, symbol: group.symbol, size: 16))
                Text(group.name).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Grubu düzenle")
            }
            if group.items.isEmpty {
                Text("Bu grup boş.\nAyarlardan menü çubuğu öğesi ekleyin.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(group.items) { ref in
                        PanelItemButton(ref: ref, image: iconProvider(ref), showLabel: showLabels, tint: Color(nsColor: group.color)) {
                            onPick(ref)
                        }
                    }
                }
            }
        }
        .padding(10)
        .fixedSize()
    }
}

private struct PanelItemButton: View {
    let ref: ItemRef
    let image: NSImage
    let showLabel: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: showLabel ? 64 : 34, maxHeight: 22)
                    .frame(height: 24)
                if showLabel {
                    Text(shortName)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 66)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? tint.opacity(0.28) : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(ref.displayName)
    }

    private var shortName: String {
        // "Uygulama – Açıklama" → mümkünse açıklama kısmı
        if let r = ref.displayName.range(of: " – ") { return String(ref.displayName[r.upperBound...]) }
        return ref.displayName
    }
}
