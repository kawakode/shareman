import AppKit
import Foundation
import ShareManCore

/// State of the ShareMan window.
@MainActor
final class AppModel: ObservableObject {
    enum ProtocolFilter: String, CaseIterable, Identifiable {
        case nfs, smb, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nfs: return "NFS"
            case .smb: return "SMB"
            case .both: return "NFS + SMB"
            }
        }
        var protocols: Set<ShareProtocol> {
            switch self {
            case .nfs: return [.nfs]
            case .smb: return [.smb]
            case .both: return [.nfs, .smb]
            }
        }
    }

    enum ListingState {
        case loading
        case loaded([NetworkShare])
        case failed(ListingFailure)
    }

    /// Why the shares of a server could not be listed, in the user's words.
    struct ListingFailure {
        /// What happened and what to do about it.
        let headline: String
        /// The tool's own error, for those who want it.
        let detail: String
        /// False when the server is not there at all: offering to mount a path would be noise.
        var serverAnswers = true
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// Optional second button (e.g. "Forcer le démontage").
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        /// Whether that button loses or changes something (shown in red).
        var actionIsDestructive = false
    }

    private enum Keys {
        static let filter = "protocolFilter"
        static let deepScan = "deepScan"
        static let subnets = "subnets"
        static let manualServers = "manualServers"
    }

    private let defaults: UserDefaults

    @Published var servers: [DiscoveredServer] = []
    @Published var selectedServerID: String?
    @Published var listings: [String: [ShareProtocol: ListingState]] = [:]
    /// Bumped whenever `listings` is emptied, so that the visible server reloads its shares.
    @Published private(set) var listingGeneration = 0
    @Published var mounted: [MountedShare] = []
    /// Mount points that are in the Finder sidebar Favorites.
    @Published var favorites: Set<String> = []

    // The scan settings and the servers added by hand are kept between launches.
    @Published var filter: ProtocolFilter {
        didSet {
            defaults.set(filter.rawValue, forKey: Keys.filter)
            // Showing "no SMB server" when SMB was never looked for would be a lie.
            if hasScanned, !filter.protocols.isSubset(of: scannedProtocols) {
                Task { await scan() }
            }
        }
    }
    @Published var deepScan: Bool {
        didSet { defaults.set(deepScan, forKey: Keys.deepScan) }
    }
    /// Optional subnets typed by the user, e.g. "10.0.0.0/24, 192.168.1.0/24".
    @Published var subnetText: String {
        didSet { defaults.set(subnetText, forKey: Keys.subnets) }
    }

    @Published var isScanning = false
    @Published var hasScanned = false
    /// Protocols the last scan looked for.
    private var scannedProtocols: Set<ShareProtocol> = []
    @Published var status = "Clique sur « Scanner » pour chercher les partages du réseau."
    @Published var warnings: [String] = []
    /// The last scan was stopped by macOS's "Local Network" privacy setting.
    @Published var localNetworkBlocked = false
    /// URLs of shares being mounted, mount points of shares being unmounted.
    @Published var busy: Set<String> = []
    /// Mount points whose Finder favorite is being added or removed.
    @Published var favoriteBusy: Set<String> = []
    @Published var alert: AlertItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _filter = Published(
            initialValue: defaults.string(forKey: Keys.filter).flatMap(ProtocolFilter.init(rawValue:)) ?? .both
        )
        _deepScan = Published(initialValue: defaults.bool(forKey: Keys.deepScan))
        _subnetText = Published(initialValue: defaults.string(forKey: Keys.subnets) ?? "")
        servers = NetworkScanner.merge(Self.loadManualServers(from: defaults))
    }

    /// Servers offering at least one of the protocols selected in the toolbar.
    var visibleServers: [DiscoveredServer] {
        servers.filter { !$0.protocols.isDisjoint(with: filter.protocols) }
    }

    var selectedServer: DiscoveredServer? {
        visibleServers.first { $0.address == selectedServerID }
    }

    // MARK: Scan

    func scan() async {
        guard !isScanning else { return }
        var options = ScanOptions()
        options.protocols = filter.protocols
        // The deep scan only concerns NFS: its button is disabled for SMB alone.
        options.deepNFS = deepScan && filter != .smb
        let typed = subnetText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map(String.init)
        if !typed.isEmpty {
            var subnets: [IPv4Subnet] = []
            for raw in typed {
                guard let subnet = IPv4Subnet(cidr: raw) else {
                    alert = AlertItem(title: "Sous-réseau invalide", message: "« \(raw) » n'est pas valide. Exemple : 10.0.0.0/24")
                    return
                }
                subnets.append(subnet)
            }
            options.subnets = subnets
        }

        isScanning = true
        warnings = []
        localNetworkBlocked = false
        let scanned = NetworkScanner.subnetsToScan(options).map(\.description).joined(separator: ", ")
        status = options.deepNFS
            ? "Scan approfondi de \(scanned.isEmpty ? "Bonjour" : scanned)…"
            : "Scan de \(scanned.isEmpty ? "Bonjour" : scanned)…"

        let result = await NetworkScanner.run(options: options)
        servers = NetworkScanner.merge(result.servers + manualServers())
        warnings = result.warnings
        localNetworkBlocked = result.blockedByLocalNetwork
        listings = [:]
        listingGeneration += 1
        isScanning = false
        hasScanned = true
        scannedProtocols = options.protocols

        // Servers added by hand are not counted: the scan did not find them.
        let found = result.servers
        if !found.isEmpty {
            status = Self.summary(of: found, scanned: options.protocols)
        } else if result.blockedByLocalNetwork {
            status = "Scan bloqué par macOS."
        } else if options.deepNFS || !options.protocols.contains(.nfs) {
            status = "Aucun serveur trouvé."
        } else {
            status = "Aucun serveur trouvé. Essaie le scan approfondi."
        }
        if selectedServer == nil { selectedServerID = visibleServers.first?.address }
        refreshMounts()

        // The protocols were changed while this scan ran: look for the new ones too.
        if !filter.protocols.isSubset(of: scannedProtocols) { await scan() }
    }

    /// "2 serveurs NFS." after an NFS scan; both counts only when both were looked for.
    static func summary(of servers: [DiscoveredServer], scanned: Set<ShareProtocol>) -> String {
        let total = servers.count == 1 ? "1 serveur" : "\(servers.count) serveurs"
        if scanned.count == 1, let only = scanned.first {
            return "\(total) \(only.displayName)."
        }
        let counts = ShareProtocol.allCases
            .filter { scanned.contains($0) }
            .map { kind in "\(servers.filter { $0.protocols.contains(kind) }.count) \(kind.displayName)" }
        return "\(total) : \(counts.joined(separator: ", "))."
    }

    /// Adds a server by hand (name or IP), for hosts the scan cannot see.
    func addServer(_ rawInput: String) {
        let host = Self.hostName(fromInput: rawInput)
        guard !host.isEmpty else { return }
        if let index = servers.firstIndex(where: { $0.address.caseInsensitiveCompare(host) == .orderedSame }) {
            // Already listed: keep what the scan learnt, just remember it as hand-added.
            servers[index].sources.insert(.manual)
            servers[index].protocols.formUnion(filter.protocols)
            selectedServerID = servers[index].address
        } else {
            let manual = DiscoveredServer(address: host, protocols: filter.protocols, sources: [.manual])
            servers = NetworkScanner.merge(servers + [manual])
            selectedServerID = host
        }
        let address = selectedServerID ?? host
        listings[address] = nil
        listingGeneration += 1
        saveManualServers()
        Task { await refineProtocols(of: address) }
    }

    /// A server added by hand is assumed to offer every selected protocol.
    /// Ask it which ones really answer, so that an NFS-only server does not
    /// show a failed SMB section.
    private func refineProtocols(of address: String) async {
        guard let answering = await NetworkScanner.protocols(answeringOn: address),
              !answering.isDisjoint(with: filter.protocols),
              let index = servers.firstIndex(where: { $0.address == address }),
              servers[index].sources == [.manual],
              servers[index].protocols != answering
        else { return }
        servers[index].protocols = answering
        saveManualServers()
    }

    /// Takes a server out of the list. One found by the scan comes back at the next scan.
    func removeServer(_ address: String) {
        servers.removeAll { $0.address == address }
        listings[address] = nil
        if selectedServerID == address { selectedServerID = visibleServers.first?.address }
        saveManualServers()
    }

    /// Accepts what people paste in the "add a server" field: a bare host, but
    /// also "nfs://host/path", "host:/path", "//user@host/Share"…
    static func hostName(fromInput raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        while host.hasPrefix("/") { host.removeFirst() }
        if let nfsPath = host.range(of: ":/") { host = String(host[..<nfsPath.lowerBound]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    private func manualServers() -> [DiscoveredServer] {
        servers
            .filter { $0.sources.contains(.manual) }
            .map { DiscoveredServer(address: $0.address, protocols: $0.protocols, sources: [.manual]) }
    }

    private func saveManualServers() {
        defaults.set(try? JSONEncoder().encode(manualServers()), forKey: Keys.manualServers)
    }

    private static func loadManualServers(from defaults: UserDefaults) -> [DiscoveredServer] {
        guard let data = defaults.data(forKey: Keys.manualServers),
              let saved = try? JSONDecoder().decode([DiscoveredServer].self, from: data)
        else { return [] }
        return saved
    }

    // MARK: Shares

    func loadSharesIfNeeded(for server: DiscoveredServer) async {
        let kinds = server.sortedProtocols.filter {
            filter.protocols.contains($0) && listings[server.address]?[$0] == nil
        }
        // NFS and SMB are asked at the same time: a slow answer to one does not hold the other.
        await withTaskGroup(of: Void.self) { group in
            for kind in kinds {
                group.addTask { await self.loadShares(for: server, kind: kind) }
            }
        }
    }

    func loadShares(for server: DiscoveredServer, kind: ShareProtocol) async {
        listings[server.address, default: [:]][kind] = .loading
        do {
            let shares = try await ShareLister.shares(of: server.address, kind: kind)
            listings[server.address, default: [:]][kind] = .loaded(shares)
        } catch {
            let failure = await Self.explain(error, listing: kind, on: server.address)
            listings[server.address, default: [:]][kind] = .failed(failure)
        }
    }

    /// `showmount` and `smbutil` fail the same way for a wrong address, a server
    /// without that service and a server that keeps its list to itself. A look
    /// at the ports tells which one it is.
    private static func explain(_ error: Error, listing kind: ShareProtocol, on address: String) async -> ListingFailure {
        let detail = error.localizedDescription
        switch await NetworkScanner.probe(host: address) {
        case .silent:
            return ListingFailure(
                headline: "Aucun service NFS ou SMB ne répond à l'adresse \(address). "
                    + "Vérifie l'adresse et que le serveur est allumé.",
                detail: detail,
                serverAnswers: false
            )
        case .answering(let open) where !open.contains(kind):
            if kind == .smb {
                return ListingFailure(
                    headline: "Ce serveur ne répond pas en SMB (port 445 fermé).",
                    detail: detail,
                    serverAnswers: false
                )
            }
            return ListingFailure(
                headline: "Ce serveur ne répond pas sur le port NFS habituel (2049) et ne donne pas sa liste d'exports. "
                    + "Si tu connais le chemin d'un export, indique-le ci-dessous.",
                detail: detail
            )
        case .answering, .unknown:
            return ListingFailure(
                headline: kind == .nfs
                    ? "Ce serveur ne donne pas sa liste d'exports. Un serveur NFSv4 seul n'en publie pas : indique alors le chemin ci-dessous."
                    : "Ce serveur ne donne pas sa liste de partages sans identifiants (accès invité refusé).",
                detail: detail
            )
        }
    }

    // MARK: Mounting

    func refreshMounts() {
        mounted = MountedShares.list()
        Task { await refreshFavorites() }
    }

    // MARK: Finder favorites

    func refreshFavorites() async {
        let mountPoints = mounted.map(\.mountPoint)
        // Off the main thread: resolving a path on a server that stopped answering can block.
        favorites = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            let inFinder = Set(FinderFavorites.paths())
            guard !inFinder.isEmpty else { return [] }
            return Set(mountPoints.filter { inFinder.contains(FinderFavorites.normalizedPath($0)) })
        }.value
    }

    /// Whether this mount point is in the Finder favorites. Called while
    /// drawing the window, so it must not touch the file system.
    func isFavorite(_ mountPoint: String) -> Bool {
        favorites.contains(mountPoint)
    }

    /// Adds the mount point to the Finder sidebar Favorites, or removes it if it is already there.
    func toggleFavorite(_ path: String) async {
        guard !favoriteBusy.contains(path) else { return }
        favoriteBusy.insert(path)
        defer { favoriteBusy.remove(path) }
        let removing = isFavorite(path)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Bool, Error> in
            do {
                if removing {
                    try FinderFavorites.remove(path: path)
                } else {
                    try FinderFavorites.add(path: path)
                }
                return .success(true)
            } catch {
                return .failure(error)
            }
        }.value
        await refreshFavorites()

        guard case .failure(let error) = result else { return }
        if case FinderFavoritesError.accessDenied = error {
            // No Finder fallback here: the way out is in System Settings.
            alert = AlertItem(
                title: "Accès aux volumes réseau refusé",
                message: "macOS ne laisse pas ShareMan accéder à « \(path) », ce qu'il exige pour l'ajouter aux favoris du Finder.\n\n"
                    + "Autorise ShareMan dans Réglages Système > Confidentialité et sécurité > Fichiers et dossiers (Volumes réseau), puis clique à nouveau sur l'étoile.",
                actionTitle: "Ouvrir les réglages…",
                action: { [weak self] in self?.openFilesAndFoldersSettings() }
            )
        } else if removing {
            alert = AlertItem(
                title: "Retrait des favoris impossible",
                message: error.localizedDescription
                    + "\n\nDans le Finder, fais un clic droit sur le partage dans la barre latérale et choisis « Retirer de la barre latérale »."
            )
        } else {
            // Fallback: select the folder in Finder so the user only has to press ⌃⌘T.
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            alert = AlertItem(
                title: "Ajout manuel nécessaire",
                message: error.localizedDescription + "\n\n" + FinderFavoritesError.manualHint
            )
        }
    }

    func mountedShare(for share: NetworkShare) -> MountedShare? {
        mounted.first { mountedShare in
            guard mountedShare.kind == share.kind,
                  let server = mountedShare.server,
                  Self.sameHost(server, share.server)
            else { return false }
            switch share.kind {
            case .nfs:
                guard let colon = mountedShare.source.range(of: ":/") else { return false }
                let path = String(mountedShare.source[mountedShare.source.index(before: colon.upperBound)...])
                return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == share.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            case .smb:
                let name = mountedShare.source.split(separator: "/").last.map(String.init) ?? ""
                let decoded = name.removingPercentEncoding ?? name
                return decoded.caseInsensitiveCompare(share.path) == .orderedSame
            }
        }
    }

    private static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ host: String) -> String {
            var host = host.lowercased()
            for suffix in ["._smb._tcp.local", "._nfs._tcp.local", ".local"] where host.hasSuffix(suffix) {
                host = String(host.dropLast(suffix.count))
            }
            return host
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// Returns true once the share is mounted (now, or already before the call).
    @discardableResult
    func mount(_ share: NetworkShare) async -> Bool {
        guard let url = share.url else { return false }
        let key = url.absoluteString
        busy.insert(key)
        defer { busy.remove(key) }

        var request = MountRequest(url: url)
        // Let macOS ask for a password itself when the server needs one.
        request.allowUI = true
        do {
            let points = try await ShareMounter.mount(request)
            refreshMounts()
            if let first = points.first ?? mountedShare(for: share)?.mountPoint {
                reveal(first)
            }
            return true
        } catch ShareManError.mountFailed(let code, _) where code == ShareMounter.userCancelledStatus {
            // The user closed macOS's password dialog: nothing to report.
            refreshMounts()
            return false
        } catch ShareManError.mountFailed(let code, let message) where code == ShareMounter.alreadyMountedStatus {
            // Mounted outside ShareMan (Finder, another name for the same server): show it.
            refreshMounts()
            if let existing = mountedShare(for: share) {
                reveal(existing.mountPoint)
            } else {
                alert = AlertItem(
                    title: "Déjà monté",
                    message: message + " Il figure dans « Partages montés », dans la barre latérale."
                )
            }
            return true
        } catch {
            refreshMounts()
            alert = AlertItem(title: "Montage impossible", message: error.localizedDescription)
            return false
        }
    }

    /// Mounts an export the server did not list (NFSv4-only servers publish no list).
    @discardableResult
    func mountExport(path rawPath: String, on server: DiscoveredServer) async -> Bool {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        if !path.hasPrefix("/") { path = "/" + path }
        return await mount(NetworkShare(server: server.address, kind: .nfs, path: path))
    }

    func unmount(_ mountedShare: MountedShare, force: Bool = false) async {
        busy.insert(mountedShare.mountPoint)
        defer { busy.remove(mountedShare.mountPoint) }
        do {
            try await ShareMounter.unmount(path: mountedShare.mountPoint, force: force)
        } catch {
            if force {
                alert = AlertItem(title: "Démontage impossible", message: error.localizedDescription)
            } else {
                alert = AlertItem(
                    title: "Démontage impossible",
                    message: error.localizedDescription
                        + "\n\nFerme les fichiers et les fenêtres ouverts sur ce partage puis réessaie. "
                        + "Forcer le démontage peut faire perdre les modifications non enregistrées.",
                    actionTitle: "Forcer le démontage",
                    action: { [weak self] in
                        Task { await self?.unmount(mountedShare, force: true) }
                    },
                    actionIsDestructive: true
                )
            }
        }
        refreshMounts()
    }

    func reveal(_ path: String) {
        // The first time, macOS asks whether ShareMan may access network volumes
        // and the plain `open(_:)` waits for the answer: called here, it froze
        // the window for as long as the question stayed on screen.
        NSWorkspace.shared.open(
            URL(fileURLWithPath: path, isDirectory: true),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// Hands an SMB server to Finder, which asks for credentials and lists the shares.
    func openInFinder(server: DiscoveredServer, kind: ShareProtocol) {
        if let url = URL(string: "\(kind.rawValue)://\(server.address)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings on the Files and Folders privacy list (Network Volumes).
    func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings on the Local Network privacy list.
    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}
