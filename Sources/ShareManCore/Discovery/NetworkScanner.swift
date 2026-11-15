import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ScanOptions: Sendable {
    /// Protocols to look for. NFS is ShareMan's priority, SMB comes second.
    public var protocols: Set<ShareProtocol> = [.nfs, .smb]
    /// Listen for Bonjour advertisements (`_nfs._tcp`, `_smb._tcp`).
    public var useBonjour = true
    /// Probe every address of the local subnets on the protocol ports.
    public var usePortScan = true
    /// Deep NFS scan: longer timeouts, larger subnets, and RPC queries to the
    /// portmapper (port 111, UDP and TCP) to find NFS servers that the port
    /// 2049 probe misses.
    public var deepNFS = false
    /// Subnets to scan. `nil` means the subnets of the Mac's active interfaces.
    public var subnets: [IPv4Subnet]?
    /// Larger subnets are narrowed to the block of this size around our address.
    /// `nil` means /22 (1022 addresses) for a normal scan and /20 for a deep scan.
    public var maxPrefix: Int?
    public var bonjourDuration: TimeInterval = 3
    /// Per-address connection timeout. A deep scan uses at least 1.5 s.
    public var connectTimeout: TimeInterval = 0.6

    public init() {}

    /// The deep scan is about NFS only: asking for it without NFS changes nothing.
    var runsDeepNFS: Bool { deepNFS && protocols.contains(.nfs) }
    var effectiveMaxPrefix: Int { maxPrefix ?? (runsDeepNFS ? 20 : 22) }
    var effectiveTimeout: TimeInterval { runsDeepNFS ? max(connectTimeout, 1.5) : connectTimeout }
}

public struct ScanResult: Sendable {
    public var servers: [DiscoveredServer]
    /// Subnets actually probed (after narrowing).
    public var scannedSubnets: [IPv4Subnet]
    public var warnings: [String]
    /// TCP probes sent, and how many the Mac refused before they left (by errno).
    public var probeCount = 0
    public var immediateFailures: [Int32: Int] = [:]
    /// True when the Mac itself refused the probes, which is what macOS's
    /// "Local Network" privacy setting does. `warnings` explains it in words.
    public var blockedByLocalNetwork = false

    /// One-line summary of the TCP probes, for troubleshooting.
    public var diagnostics: String {
        let refused = immediateFailures
            .sorted { $0.key < $1.key }
            .map { "\(String(cString: strerror($0.key))) ×\($0.value)" }
            .joined(separator: ", ")
        return "\(probeCount) connexions TCP tentées" + (refused.isEmpty ? "." : " ; refusées localement : \(refused).")
    }
}

/// Finds NFS and SMB servers on the local network.
public enum NetworkScanner {
    public static func scan(options: ScanOptions = ScanOptions()) async -> [DiscoveredServer] {
        await run(options: options).servers
    }

    public static func run(options: ScanOptions = ScanOptions()) async -> ScanResult {
        let protocols = ShareProtocol.allCases.filter { options.protocols.contains($0) }
        let subnets = subnetsToScan(options)
        guard !protocols.isEmpty else {
            return ScanResult(servers: [], scannedSubnets: subnets, warnings: [])
        }

        async let bonjourResults: [DiscoveredServer] = options.useBonjour
            ? bonjourScan(protocols: protocols, duration: options.bonjourDuration)
            : []
        async let portResults: PortScanOutcome = options.usePortScan
            ? portScan(protocols: protocols, subnets: subnets, options: options)
            : PortScanOutcome()

        let outcome = await portResults
        var servers = merge(await bonjourResults + outcome.servers)
        if options.subnets == nil {
            // An automatic scan is about the other machines: this Mac's own
            // file sharing is not something to mount on itself.
            let own = Set(LocalNetwork.activeIPv4Subnets().map { IPv4Subnet.format($0.address) })
            servers.removeAll { own.contains($0.address) }
        }
        var warnings = outcome.warnings
        if options.usePortScan {
            warnings += narrowingWarnings(options)
        }
        if options.usePortScan && subnets.isEmpty {
            warnings.append("Aucune interface réseau IPv4 active : rien à scanner.")
        }
        return ScanResult(
            servers: servers,
            scannedSubnets: subnets,
            warnings: warnings,
            probeCount: outcome.probeCount,
            immediateFailures: outcome.immediateFailures,
            blockedByLocalNetwork: outcome.blockedLocally
        )
    }

    /// Subnets that a scan with these options would cover, already narrowed.
    public static func subnetsToScan(_ options: ScanOptions) -> [IPv4Subnet] {
        let subnets = options.subnets ?? LocalNetwork.activeIPv4Subnets()
        // Two interfaces on the same network (Wi-Fi + Ethernet) are scanned once.
        var seen = Set<String>()
        return subnets
            .map { $0.narrowed(to: options.effectiveMaxPrefix) }
            .filter { seen.insert($0.description).inserted }
    }

    /// One warning per network too large to be probed entirely: servers
    /// outside the probed block would otherwise be missed without a word.
    static func narrowingWarnings(_ options: ScanOptions) -> [String] {
        let limit = options.effectiveMaxPrefix
        var seen = Set<String>()
        return (options.subnets ?? LocalNetwork.activeIPv4Subnets())
            .filter { $0.prefixLength < limit && seen.insert($0.description).inserted }
            .map { subnet in
                "Le réseau \(subnet) est trop grand pour être parcouru en entier : seul "
                    + "\(subnet.narrowed(to: limit)) est scanné. Indique un sous-réseau plus précis pour chercher ailleurs."
            }
    }

    /// Protocols whose port answers on `host`, for a server added by hand.
    /// Returns nil when `host` is not an IPv4 address or nothing answered, in
    /// which case the caller cannot tell and should try every protocol.
    public static func protocols(answeringOn host: String, timeout: TimeInterval = 1) async -> Set<ShareProtocol>? {
        guard let address = IPv4Subnet.parseAddress(host) else { return nil }
        let result = await PortScanner.scan(hosts: [address], ports: ShareProtocol.allCases.map(\.port), timeout: timeout)
        let found = Set(ShareProtocol.allCases.filter { result.open[address]?.contains($0.port) == true })
        return found.isEmpty ? nil : found
    }

    static func bonjourScan(protocols: [ShareProtocol], duration: TimeInterval) async -> [DiscoveredServer] {
        await withTaskGroup(of: [DiscoveredServer].self) { group in
            for kind in protocols {
                group.addTask {
                    await BonjourBrowser.discover(serviceType: kind.bonjourType, browseDuration: duration).map {
                        DiscoveredServer(address: $0.address, bonjourName: $0.name, protocols: [kind], sources: [.bonjour])
                    }
                }
            }
            var all: [DiscoveredServer] = []
            for await servers in group { all += servers }
            return all
        }
    }

    struct PortScanOutcome: Sendable {
        var servers: [DiscoveredServer] = []
        var warnings: [String] = []
        var probeCount = 0
        var immediateFailures: [Int32: Int] = [:]
        var blockedLocally = false
    }

    static func portScan(
        protocols: [ShareProtocol],
        subnets: [IPv4Subnet],
        options: ScanOptions
    ) async -> PortScanOutcome {
        let hosts = Array(Set(subnets.flatMap { $0.hostAddresses(maxPrefix: options.effectiveMaxPrefix) })).sorted()
        guard !hosts.isEmpty else { return PortScanOutcome() }

        var ports = protocols.map(\.port)
        if options.runsDeepNFS { ports.append(RPCPortmapper.portmapperPort) }

        // The UDP RPC sweep runs alongside the TCP scan.
        async let rpcFound: [UInt32: UInt16] = options.runsDeepNFS
            ? RPCPortmapper.findNFSServers(
                hosts: hosts,
                broadcastAddresses: subnets.compactMap(\.broadcastAddress),
                timeout: max(2, options.effectiveTimeout)
            )
            : [:]
        let tcp = await PortScanner.scan(hosts: hosts, ports: ports, timeout: options.effectiveTimeout)
        var nfsByRPC = await rpcFound

        // Hosts with rpcbind reachable over TCP but silent over UDP: ask over TCP.
        if options.runsDeepNFS {
            let candidates = tcp.open
                .filter { $0.value.contains(RPCPortmapper.portmapperPort) && nfsByRPC[$0.key] == nil }
                .map(\.key)
            let timeout = options.effectiveTimeout
            let tcpAnswers = await withTaskGroup(of: (UInt32, UInt16?).self) { group in
                for host in candidates {
                    group.addTask {
                        (host, RPCPortmapper.nfsPortOverTCP(host: host, timeout: max(2, timeout)))
                    }
                }
                var answers: [(UInt32, UInt16?)] = []
                for await answer in group { answers.append(answer) }
                return answers
            }
            for case let (host, port?) in tcpAnswers { nfsByRPC[host] = port }
        }

        var servers: [DiscoveredServer] = tcp.open.compactMap { host, openPorts in
            var found = Set(protocols.filter { openPorts.contains($0.port) })
            if nfsByRPC[host] != nil { found.insert(.nfs) }
            guard !found.isEmpty else { return nil }
            return DiscoveredServer(address: IPv4Subnet.format(host), protocols: found, sources: [.portScan])
        }
        let alreadyListed = Set(tcp.open.keys)
        for host in nfsByRPC.keys where !alreadyListed.contains(host) {
            servers.append(DiscoveredServer(address: IPv4Subnet.format(host), protocols: [.nfs], sources: [.rpc]))
        }
        // Mark RPC confirmation on port-scan hits as well.
        servers = servers.map { server in
            var server = server
            if let ip = IPv4Subnet.parseAddress(server.address), nfsByRPC[ip] != nil {
                server.sources.insert(.rpc)
            }
            return server
        }

        var warnings: [String] = []
        let blockedLocally = tcp.looksBlockedLocally && nfsByRPC.isEmpty
        if blockedLocally {
            warnings.append(
                "macOS a refusé presque toutes les connexions avant qu'elles partent sur le réseau. "
                + "Si tu attendais des serveurs, autorise l'app (ou le Terminal) dans "
                + "Réglages Système > Confidentialité et sécurité > Réseau local, puis relance le scan."
            )
        }
        return PortScanOutcome(
            servers: servers,
            warnings: warnings,
            probeCount: tcp.probeCount,
            immediateFailures: tcp.immediateFailures,
            blockedLocally: blockedLocally
        )
    }

    /// Merges duplicates (same address) and sorts: NFS servers first, then by address.
    public static func merge(_ servers: [DiscoveredServer]) -> [DiscoveredServer] {
        var byAddress: [String: DiscoveredServer] = [:]
        for server in servers {
            if var existing = byAddress[server.address] {
                existing.protocols.formUnion(server.protocols)
                existing.sources.formUnion(server.sources)
                existing.bonjourName = existing.bonjourName ?? server.bonjourName
                byAddress[server.address] = existing
            } else {
                byAddress[server.address] = server
            }
        }
        return byAddress.values.sorted { lhs, rhs in
            let lhsNFS = lhs.protocols.contains(.nfs)
            let rhsNFS = rhs.protocols.contains(.nfs)
            if lhsNFS != rhsNFS { return lhsNFS }
            return addressSortKey(lhs.address) < addressSortKey(rhs.address)
        }
    }

    private static func addressSortKey(_ address: String) -> String {
        if let ip = IPv4Subnet.parseAddress(address) {
            return String(format: "0-%010u", ip)
        }
        return "1-" + address.lowercased()
    }
}
