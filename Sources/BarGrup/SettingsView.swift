import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GroupsTab()
                .tabItem { Label("Gruplar", systemImage: "square.grid.2x2") }
            GeneralTab()
                .tabItem { Label("Genel", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - İzin bandı

struct PermissionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.accessibilityGranted {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("**Erişilebilirlik izni** gerekli: menü çubuğu öğelerini bulmak, açmak ve taşımak için.")
                Spacer()
                Button("İzin ver…") {
                    AX.requestTrust()
                    model.openPrivacyPane("Privacy_Accessibility")
                }
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Gruplar sekmesi

struct GroupsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PermissionBanner()
            HStack(spacing: 0) {
                groupList
                    .frame(width: 210)
                Divider()
                Group {
                    if let id = model.selectedGroupID, let binding = model.groupBinding(id) {
                        GroupEditor(group: binding)
                            .id(id)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("Bir grup seçin ya da + ile yeni grup ekleyin.")
                                .foregroundStyle(.secondary)
                            Button("Yeni grup ekle") { model.addGroup() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            footer
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedGroupID) {
                ForEach(model.config.groups) { g in
                    HStack(spacing: 8) {
                        Image(nsImage: Icons.groupIcon(colorHex: g.colorHex, symbol: g.symbol, size: 20))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).lineLimit(1)
                            Text("\(g.items.count) öğe").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(g.id)
                    .contextMenu {
                        Button("Grubu sil", role: .destructive) { model.removeGroup(g.id) }
                    }
                }
                .onMove { model.moveGroups(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            Text("Sürükleyerek sıralayın; menü çubuğundaki sıra da değişir.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 4)
            Divider()
            HStack(spacing: 0) {
                Button { model.addGroup() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 22)
                }
                .help("Grup ekle")
                Divider().frame(height: 16)
                Button {
                    if let id = model.selectedGroupID { confirmDelete(id) }
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 22)
                }
                .disabled(model.selectedGroupID == nil)
                .help("Seçili grubu sil")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private func confirmDelete(_ id: UUID) {
        guard let g = model.config.groups.first(where: { $0.id == id }) else { return }
        if g.items.isEmpty { model.removeGroup(id); return }
        let alert = NSAlert()
        alert.messageText = "“\(g.name)” grubu silinsin mi?"
        alert.informativeText = "Gruptaki \(g.items.count) öğe gruptan çıkarılır. Öğeler menü çubuğunda gizli kalabilir; görünür yapmak için “Yerleştir”i kullanın."
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "Vazgeç")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { model.removeGroup(id) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.rescan()
            } label: {
                Label("Menü çubuğunu tara", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || !model.accessibilityGranted)

            Button {
                model.startArrange()
            } label: {
                Label("Öğeleri yerleştir", systemImage: "arrow.left.arrow.right")
            }
            .disabled(model.isArranging || !model.accessibilityGranted)
            .help("Gruptaki öğeleri ayracın soluna (gizli), diğerlerini sağına (görünür) ⌘-sürükleyerek taşır.")

            if model.isScanning || model.isArranging { ProgressView().controlSize(.small) }
            if let report = model.arrangeReport {
                Text(report).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.top, 10)
    }
}

// MARK: - Grup düzenleyici

struct GroupEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var group: ItemGroup
    @State private var filter = ""
    @State private var showSystem = false

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(nsColor: group.color) },
                set: { group.colorHex = NSColor($0).hexString })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            appearance
            Divider()
            HStack(alignment: .top, spacing: 12) {
                members
                available
            }
        }
        .padding(14)
    }

    private var appearance: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: Icons.groupIcon(colorHex: group.colorHex, symbol: group.symbol, size: 44))
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Grup adı", text: $group.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    ColorPicker("Renk", selection: colorBinding, supportsOpacity: false)
                        .fixedSize()
                }
                HStack(spacing: 5) {
                    ForEach(Palette.presets, id: \.self) { hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary, lineWidth: group.colorHex.uppercased() == hex ? 2 : 0))
                            .onTapGesture { group.colorHex = hex }
                            .help(hex)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Palette.symbols, id: \.self) { sym in
                            Button { group.symbol = sym } label: {
                                Image(systemName: sym)
                                    .frame(width: 24, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(group.symbol == sym ? Color(nsColor: group.color).opacity(0.35) : Color.clear))
                            }
                            .buttonStyle(.borderless)
                            .help(sym)
                        }
                    }
                }
            }
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gruptaki öğeler (\(group.items.count))").font(.headline)
            Text("Sürükleyerek sıralayın. Panelde bu sırayla görünür.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(group.items) { ref in
                    ItemRow(ref: ref, trailing: AnyView(
                        Button { model.remove(ref, from: group.id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Gruptan çıkar")
                    ), showState: true)
                }
                .onMove { model.moveItems(in: group.id, from: $0, to: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if group.items.isEmpty {
                    Text("Sağdaki listeden öğe ekleyin →").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var available: some View {
        let inGroup = Set(group.items.map(\.key)).union(model.liveKeysMatched(by: group.items))
        let all = model.catalog.filter { !inGroup.contains($0.key) }
        let shown = filter.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(filter) || $0.bundleID.localizedCaseInsensitiveContains(filter) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Menü çubuğundaki öğeler").font(.headline)
            TextField("Ara", text: $filter).textFieldStyle(.roundedBorder)
            List {
                let apps = shown.filter { !Icons.isSystemItem($0) }
                let system = shown.filter { Icons.isSystemItem($0) }
                Section("Uygulamalar (\(apps.count))") {
                    ForEach(apps) { ref in availableRow(ref) }
                }
                if !system.isEmpty {
                    Section {
                        DisclosureGroup("Sistem öğeleri (\(system.count))", isExpanded: $showSystem) {
                            ForEach(system) { ref in availableRow(ref) }
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if !model.accessibilityGranted {
                    Text("Öğeleri listelemek için Erişilebilirlik izni verin.").foregroundStyle(.secondary).padding()
                } else if model.isScanning && all.isEmpty {
                    ProgressView()
                } else if shown.isEmpty {
                    Text("Öğe bulunamadı.").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func availableRow(_ ref: ItemRef) -> some View {
        let other = model.group(containing: ref)
        return ItemRow(ref: ref, subtitle: other.map { "“\($0.name)” grubunda" }, trailing: AnyView(
            Button { model.add(ref, to: group.id) } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help(other == nil ? "Gruba ekle" : "Bu gruba taşı")
        ), showState: true)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let ref: ItemRef
    var subtitle: String? = nil
    let trailing: AnyView
    var showState = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: model.icon(for: ref))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(ref.displayName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if showState { stateBadge }
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.orange) }
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 1)
        .help("\(ref.displayName)\n\(ref.bundleID)")
    }

    @ViewBuilder private var stateBadge: some View {
        switch model.state(of: ref) {
        case .visible: Label("görünür", systemImage: "eye").font(.caption2).foregroundStyle(.secondary)
        case .hidden: Label("gizli", systemImage: "eye.slash").font(.caption2).foregroundStyle(.secondary)
        case .missing: Label("çalışmıyor", systemImage: "moon.zzz").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Genel sekmesi

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Davranış") {
                Toggle("Gruplanmış öğeleri menü çubuğunda gizle", isOn: $model.config.hidingEnabled)
                Toggle("Gizli bir öğeyi açarken gizli bölümü geçici olarak göster", isOn: $model.config.revealWhenOpening)
                    .disabled(!model.config.hidingEnabled)
                Stepper(value: $model.config.autoRehideSeconds, in: 0...300, step: 5) {
                    Text(model.config.autoRehideSeconds == 0
                         ? "Elle gösterilen öğeler otomatik gizlenmesin"
                         : "Elle gösterilen öğeleri \(model.config.autoRehideSeconds) sn sonra tekrar gizle")
                }
                .disabled(!model.config.hidingEnabled)
                Toggle("Panelde öğe adlarını göster", isOn: $model.config.showLabels)
                Toggle("Oturum açılışında başlat", isOn: Binding(get: { model.launchAtLogin },
                                                                 set: { model.setLaunchAtLogin($0) }))
            }
            Section("İzinler") {
                permissionRow("Erişilebilirlik", granted: model.accessibilityGranted,
                              detail: "Öğeleri bulmak, açmak ve taşımak için gerekli.") {
                    AX.requestTrust(); model.openPrivacyPane("Privacy_Accessibility")
                }
            }
            Section("Nasıl çalışır?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Menü çubuğunda BarGrup bir **ayraç** (⁄), her grup için **renkli bir simge** ve bir **‹ ›** düğmesi ekler.")
                    Text("• Ayracın **solundaki** öğeler gizlenir. Gruplara eklediğiniz öğeleri “Öğeleri yerleştir” ile otomatik ya da ⌘ tuşuna basılı tutup sürükleyerek elle oraya taşıyın.")
                    Text("• Grup simgesine tıklayınca gruptaki öğeler bir panelde açılır; bir öğeye tıklamak onun menüsünü açar.")
                    Text("• ‹ › düğmesi tüm gizli öğeleri geçici olarak gösterir. Sağ tık: menü (Ayarlar, Yerleştir, Çıkış).")
                    Text("• Gruplarınız `~/Library/Application Support/BarGrup/config.json` dosyasında saklanır ve açılışta geri yüklenir.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Ayarları aç…", action: action) }
        }
    }
}
