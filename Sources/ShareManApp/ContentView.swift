import AppKit
import ShareManCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manualHost = ""
    /// The list writes its selection while SwiftUI updates the views. Kept in
    /// view state and copied to the model afterwards: bound straight to the
    /// model, every click logged "Publishing changes from within view updates".
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if !model.warnings.isEmpty {
                    WarningBanner()
                    Divider()
                }
                if let server = model.selectedServer {
                    ServerDetailView(server: server)
                        .id(server.address)
                } else {
                    PlaceholderView()
                }
            }
        }
        .toolbar { toolbarContent }
        .alert(item: $model.alert) { item in
            if let actionTitle = item.actionTitle, let action = item.action {
                return Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    primaryButton: item.actionIsDestructive
                        ? .destructive(Text(actionTitle), action: action)
                        : .default(Text(actionTitle), action: action),
                    secondaryButton: .cancel(Text("Annuler"))
                )
            }
            return Alert(title: Text(item.title), message: Text(item.message))
        }
        // The window opens on fresh results instead of an empty list.
        .task {
            if !model.hasScanned { await model.scan() }
        }
        .onAppear { model.refreshMounts() }
        // Shares mounted, unmounted or starred in Finder show up here without a new scan.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshMounts()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshMounts()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshMounts()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Serveurs") {
                    if model.visibleServers.isEmpty {
                        Text(emptyServersText)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.visibleServers, id: \.address) { server in
                        ServerRow(server: server)
                            .tag(server.address)
                            .contextMenu {
                                Button("Copier l'adresse") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(server.address, forType: .string)
                                }
                                Button("Retirer de la liste") { model.removeServer(server.address) }
                            }
                    }
                }
                if !model.mounted.isEmpty {
                    Section("Partages montés") {
                        ForEach(model.mounted, id: \.mountPoint) { share in
                            MountedRow(share: share)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { selection = model.selectedServerID }
            .onChange(of: selection) { newValue in
                if model.selectedServerID != newValue { model.selectedServerID = newValue }
            }
            .onChange(of: model.selectedServerID) { newValue in
                if selection != newValue { selection = newValue }
            }
            .onDeleteCommand {
                if let address = model.selectedServerID { model.removeServer(address) }
            }

            Divider()
            HStack(spacing: 6) {
                TextField("Ajouter un serveur (IP ou nom)", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualHost)
                Button(action: addManualHost) {
                    Label("Ajouter ce serveur à la liste", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Ajouter ce serveur à la liste")
            }
            .padding(8)

            StatusBar()
        }
    }

    private var emptyServersText: String {
        if model.isScanning { return "Recherche en cours…" }
        if !model.servers.isEmpty { return "Aucun serveur \(model.filter.label)" }
        return model.hasScanned ? "Aucun serveur trouvé" : "Pas encore de scan"
    }

    private func addManualHost() {
        model.addServer(manualHost)
        manualHost = ""
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Separate items, in this order: when the window is narrow macOS hides
        // the last ones first, and the scan button must not be one of them.
        ToolbarItem(placement: .primaryAction) {
            Picker("Protocoles", selection: $model.filter) {
                ForEach(AppModel.ProtocolFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .help("Protocoles à rechercher et à afficher")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.scan() }
            } label: {
                if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scan en cours…")
                    }
                } else {
                    Label("Scanner", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            }
            .disabled(model.isScanning)
            .help("Chercher les serveurs (⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            ScanOptionsButton()
        }
    }
}

/// Deep scan and subnets: settings changed rarely, kept out of the toolbar so
/// that the scan button always fits.
struct ScanOptionsButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShown = false

    private var summary: String {
        var active: [String] = []
        if model.deepScan && model.filter != .smb { active.append("scan approfondi") }
        let subnets = model.subnetText.trimmingCharacters(in: .whitespaces)
        if !subnets.isEmpty { active.append("sous-réseau \(subnets)") }
        return active.isEmpty
            ? "Options de scan : scan approfondi, sous-réseau"
            : "Options de scan actives : " + active.joined(separator: ", ")
    }

    private var hasActiveOption: Bool {
        (model.deepScan && model.filter != .smb) || !model.subnetText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Label("Options de scan", systemImage: "slider.horizontal.3")
                .overlay(alignment: .topTrailing) {
                    // A dot tells that a scan option is on without opening the popover.
                    if hasActiveOption {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .help(summary)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Scan NFS approfondi", isOn: $model.deepScan)
                    .disabled(model.filter == .smb)
                Text("Parcourt le sous-réseau entier, attend plus longtemps et interroge le port 111 (RPC). "
                    + "Plus lent, mais trouve les serveurs NFS qui échappent au scan rapide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 4)

                Text("Sous-réseau à scanner")
                TextField("Automatique", text: $model.subnetText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(scan)
                Text("Facultatif. Exemple : 10.0.0.0/24. Plusieurs valeurs séparées par des virgules. "
                    + "Vide, ShareMan scanne les réseaux de ce Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Scanner", action: scan)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isScanning)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private func scan() {
        isShown = false
        Task { await model.scan() }
    }
}

// MARK: - Rows

struct ProtocolBadge: View {
    let kind: ShareProtocol

    var body: some View {
        Text(kind.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kind == .nfs ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(kind == .nfs ? Color.blue : Color.orange)
    }
}

struct ServerRow: View {
    let server: DiscoveredServer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)
                if server.bonjourName != nil {
                    Text(server.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            ForEach(server.sortedProtocols, id: \.self) { ProtocolBadge(kind: $0) }
        }
        .padding(.vertical, 2)
    }
}

struct MountedRow: View {
    @EnvironmentObject private var model: AppModel
    let share: MountedShare

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text((share.mountPoint as NSString).lastPathComponent)
                    .lineLimit(1)
                Text(share.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.busy.contains(share.mountPoint) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.reveal(share.mountPoint)
                } label: {
                    Label("Ouvrir dans le Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Ouvrir dans le Finder")
                FavoriteButton(path: share.mountPoint)
                    .buttonStyle(.borderless)
                Button {
                    Task { await model.unmount(share) }
                } label: {
                    Label("Démonter", systemImage: "eject")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Démonter")
            }
        }
        .help(share.mountPoint)
    }
}

/// Star that adds a mounted share to the Finder sidebar Favorites, or removes it.
struct FavoriteButton: View {
    @EnvironmentObject private var model: AppModel
    let path: String

    var body: some View {
        let isFavorite = model.isFavorite(path)
        let title = isFavorite ? "Retirer des favoris du Finder" : "Ajouter aux favoris du Finder"
        Button {
            Task { await model.toggleFavorite(path) }
        } label: {
            Label(title, systemImage: isFavorite ? "star.fill" : "star")
                .labelStyle(.iconOnly)
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
        }
        .help(title)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }
}

/// What went wrong during the last scan, where it cannot be missed, with the
/// way out when macOS's Local Network setting is the cause.
struct WarningBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.warnings, id: \.self) { warning in
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if model.localNetworkBlocked {
                    Button("Ouvrir les réglages Réseau local…") { model.openLocalNetworkSettings() }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}

struct PlaceholderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.isScanning {
                ProgressView()
                    .controlSize(.large)
                Text("Recherche des serveurs…")
                    .font(.title3)
                Text(model.status)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "network")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(model.visibleServers.isEmpty ? "Aucun serveur" : "Choisis un serveur")
                    .font(.title3)
                Text("Lance un scan pour trouver les partages NFS et SMB du réseau.\nSi un serveur NFS n'apparaît pas, active le scan approfondi dans les options de scan ou ajoute-le à la main.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Scanner") { Task { await model.scan() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Server detail

/// What makes the detail view (re)load its shares: the protocols shown, and
/// every time the lists are emptied by a scan.
private struct ListingLoadKey: Equatable {
    let filter: AppModel.ProtocolFilter
    let generation: Int
}

struct ServerDetailView: View {
    @EnvironmentObject private var model: AppModel
    let server: DiscoveredServer

    private var kinds: [ShareProtocol] {
        server.sortedProtocols.filter { model.filter.protocols.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(kinds, id: \.self) { kind in
                    listingSection(kind)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: ListingLoadKey(filter: model.filter, generation: model.listingGeneration)) {
            await model.loadSharesIfNeeded(for: server)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.displayName)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                if server.sources.contains(.manual) {
                    Button("Retirer de la liste") { model.removeServer(server.address) }
                        .controlSize(.small)
                        .help("Retirer ce serveur ajouté à la main (touche Suppr dans la liste)")
                }
            }
            HStack(spacing: 6) {
                if server.bonjourName != nil {
                    Text(server.address)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(server.sortedProtocols, id: \.self) { ProtocolBadge(kind: $0) }
                Text("Trouvé par : " + server.sources.sorted().map(sourceLabel).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceLabel(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour: return "Bonjour"
        case .portScan: return "scan de ports"
        case .rpc: return "RPC"
        case .manual: return "ajout à la main"
        }
    }

    @ViewBuilder
    private func listingSection(_ kind: ShareProtocol) -> some View {
        let state = model.listings[server.address]?[kind]
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case .none, .loading?:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(kind == .nfs ? "Lecture des exports…" : "Lecture des partages…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                case .failed(let failure)?:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(failure.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Réessayer") { Task { await model.loadShares(for: server, kind: kind) } }
                            if kind == .smb, failure.serverAnswers {
                                Button("Se connecter avec le Finder…") { model.openInFinder(server: server, kind: kind) }
                            }
                        }
                    }
                    .padding(8)
                case .loaded(let shares)?:
                    if shares.isEmpty {
                        Text(kind == .nfs ? "Aucun export visible." : "Aucun partage visible.")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    ForEach(Array(shares.enumerated()), id: \.element) { index, share in
                        if index > 0 { Divider() }
                        ShareRow(share: share)
                    }
                }
                if kind == .nfs, showsManualExport(state) {
                    Divider()
                    ManualExportRow(server: server)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                ProtocolBadge(kind: kind)
                Text(kind == .nfs ? "Exports NFS" : "Partages SMB")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.loadShares(for: server, kind: kind) }
                } label: {
                    Label("Recharger", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Recharger")
            }
        }
    }

    /// The path field appears once the listing has answered, one way or the other.
    private func showsManualExport(_ state: AppModel.ListingState?) -> Bool {
        switch state {
        case .loaded?: return true
        case .failed(let failure)?: return failure.serverAnswers
        case .none, .loading?: return false
        }
    }
}

/// Mounts an export by its path, for what the server does not list.
struct ManualExportRow: View {
    @EnvironmentObject private var model: AppModel
    let server: DiscoveredServer
    @State private var path = ""
    @State private var isMounting = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Monter un autre export par son chemin, ex. /volume1/data", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(mount)
                .disabled(isMounting)
            if isMounting {
                // A refused mount can take a quarter of a minute to say so.
                ProgressView().controlSize(.small)
                Text("Montage…")
                    .foregroundStyle(.secondary)
            } else {
                Button("Monter", action: mount)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func mount() {
        let wanted = path
        guard !isMounting, !wanted.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isMounting = true
        Task {
            let mounted = await model.mountExport(path: wanted, on: server)
            isMounting = false
            if mounted { path = "" }
        }
    }
}

struct ShareRow: View {
    @EnvironmentObject private var model: AppModel
    let share: NetworkShare

    var body: some View {
        let mounted = model.mountedShare(for: share)
        let isBusy = share.url.map { model.busy.contains($0.absoluteString) } ?? false
            || mounted.map { model.busy.contains($0.mountPoint) } ?? false

        HStack(spacing: 10) {
            Image(systemName: mounted == nil ? "folder" : "folder.fill")
                .foregroundStyle(mounted == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(share.path)
                    .textSelection(.enabled)
                if let mounted {
                    Text("Monté sur \(mounted.mountPoint)")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if !share.allowedClients.isEmpty {
                    Text("Autorisé : " + share.allowedClients.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let comment = share.comment {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if let mounted {
                FavoriteButton(path: mounted.mountPoint)
                    .buttonStyle(.borderless)
                Button("Ouvrir") { model.reveal(mounted.mountPoint) }
                Button("Démonter") { Task { await model.unmount(mounted) } }
            } else {
                Button("Monter") { Task { await model.mount(share) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
