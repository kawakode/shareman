import XCTest
@testable import ShareManCore

final class ShowmountParserTests: XCTestCase {
    func testParsesExportsAndClients() {
        let output = """
        Exports list on 192.168.1.10:
        /volume1/media                     192.168.1.0/24
        /volume1/backup                    Everyone
        /srv/nfs/home                      10.0.0.2 10.0.0.3
        """
        let exports = ShowmountParser.parse(output)
        XCTAssertEqual(exports.map(\.path), ["/volume1/media", "/volume1/backup", "/srv/nfs/home"])
        XCTAssertEqual(exports[0].clients, ["192.168.1.0/24"])
        XCTAssertEqual(exports[1].clients, ["Everyone"])
        XCTAssertEqual(exports[2].clients, ["10.0.0.2", "10.0.0.3"])
    }

    /// Real `showmount -e` output: the path is padded to 35 characters, then a space.
    func testKeepsSpacesInPathsShorterThanTheColumn() {
        let output = [
            "Exports list on 10.0.0.40:",
            "/POOL1/subvol-3001-disk-0           10.0.0.0/24",
            "/volume1/Mes films                  10.0.0.0/24 10.0.1.0/24",
            "/mnt/d5                             *",
            "/volume1/Photos de famille          Everyone",
        ].joined(separator: "\n")
        let exports = ShowmountParser.parse(output)
        XCTAssertEqual(exports.map(\.path), [
            "/POOL1/subvol-3001-disk-0", "/volume1/Mes films", "/mnt/d5", "/volume1/Photos de famille",
        ])
        XCTAssertEqual(exports[1].clients, ["10.0.0.0/24", "10.0.1.0/24"])
        XCTAssertEqual(exports[2].clients, ["*"])
        XCTAssertEqual(exports[3].clients, ["Everyone"])
    }

    func testPathFillingOrOverflowingTheColumn() {
        let output = [
            "/srv/exports/path-of-35-characters0 10.0.0.0/24",
            "/srv/exports/a/much/longer/path/than/the/column 10.0.0.2 10.0.0.3",
        ].joined(separator: "\n")
        let exports = ShowmountParser.parse(output)
        XCTAssertEqual(exports.map(\.path), [
            "/srv/exports/path-of-35-characters0",
            "/srv/exports/a/much/longer/path/than/the/column",
        ])
        XCTAssertEqual(exports[0].clients, ["10.0.0.0/24"])
        XCTAssertEqual(exports[1].clients, ["10.0.0.2", "10.0.0.3"])
    }

    func testEmptyListGivesNoExports() {
        XCTAssertTrue(ShowmountParser.parse("Exports list on nas:\n").isEmpty)
    }
}

final class SmbutilParserTests: XCTestCase {
    let output = """
    Share                                           Type    Comments
    -------------------------------
    Public                                          Disk
    Time Machine                                    Disk    Sauvegardes du Mac
    photo                                           Disk    System default shared folder
    IPC$                                            Pipe    IPC Service (Samba 4.15.13)
    ADMIN$                                          Disk

    5 shares listed
    """

    func testParsesNamesTypesAndComments() {
        let shares = SmbutilParser.parse(output)
        XCTAssertEqual(shares.map(\.name), ["Public", "Time Machine", "photo", "IPC$", "ADMIN$"])
        XCTAssertEqual(shares[0].comment, nil)
        XCTAssertEqual(shares[1].comment, "Sauvegardes du Mac")
        XCTAssertEqual(shares[3].type, "Pipe")
    }

    func testHiddenAndDiskFlags() {
        let shares = SmbutilParser.parse(output)
        let visibleDisks = shares.filter { $0.isDisk && !$0.isHidden }.map(\.name)
        XCTAssertEqual(visibleDisks, ["Public", "Time Machine", "photo"])
    }
}

final class SmbutilColumnTests: XCTestCase {
    private func row(_ name: String, _ type: String, _ comment: String = "") -> String {
        // Same layout as smbutil: "%-48s%-8s%s".
        let paddedName = name.padding(toLength: max(48, name.count), withPad: " ", startingAt: 0)
        let paddedType = type.padding(toLength: 8, withPad: " ", startingAt: 0)
        return paddedName + paddedType + comment
    }

    func testNameContainingATypeWordStaysWhole() {
        let output = [
            row("Share", "Type", "Comments"),
            "-------------------------------",
            row("USB Disk 1", "Disk", "Disque externe"),
            row("Old Printer Drivers", "Disk"),
            row("Imprimante du bureau", "Printer", "Disk tray 2"),
            "",
            "3 shares listed",
        ].joined(separator: "\n")
        let shares = SmbutilParser.parse(output)
        XCTAssertEqual(shares.map(\.name), ["USB Disk 1", "Old Printer Drivers", "Imprimante du bureau"])
        XCTAssertEqual(shares.map(\.type), ["Disk", "Disk", "Printer"])
        XCTAssertEqual(shares[0].comment, "Disque externe")
        XCTAssertNil(shares[1].comment)
        XCTAssertEqual(shares[2].comment, "Disk tray 2")
    }

    func testAccentedNameIsCutAtTheRightColumn() {
        // "é" is two bytes: the type column moves when counted in bytes.
        let byteAligned = "Vidéos" + String(repeating: " ", count: 48 - "Vidéos".utf8.count) + "Disk    Films"
        let characterAligned = "Vidéos" + String(repeating: " ", count: 48 - "Vidéos".count) + "Disk    Films"
        for line in [byteAligned, characterAligned] {
            let shares = SmbutilParser.parse("-------\n" + line)
            XCTAssertEqual(shares.map(\.name), ["Vidéos"])
            XCTAssertEqual(shares.first?.comment, "Films")
        }
    }
}

final class ShareURLTests: XCTestCase {
    func testBuildsNFSURLWithEncodedPath() {
        let url = ShareURL.make(kind: .nfs, host: "nas.local", path: "/volume1/Mes films")
        XCTAssertEqual(url?.absoluteString, "nfs://nas.local/volume1/Mes%20films")
    }

    func testBuildsSMBURLWithUser() {
        let url = ShareURL.make(kind: .smb, host: "192.168.1.10", path: "Time Machine", user: "bob")
        XCTAssertEqual(url?.absoluteString, "smb://bob@192.168.1.10/Time%20Machine")
    }

    func testParsesClassicNFSNotation() throws {
        XCTAssertEqual(try ShareURL.parse("nas:/volume1/media").absoluteString, "nfs://nas/volume1/media")
        XCTAssertEqual(try ShareURL.parse("192.168.1.10:/srv/nfs").absoluteString, "nfs://192.168.1.10/srv/nfs")
    }

    func testParsesClassicSMBNotation() throws {
        XCTAssertEqual(try ShareURL.parse("//nas/Public").absoluteString, "smb://nas/Public")
        XCTAssertEqual(try ShareURL.parse("//bob@nas/Public").absoluteString, "smb://bob@nas/Public")
    }

    func testParsesURLsAndNormalisesCIFS() throws {
        XCTAssertEqual(try ShareURL.parse("nfs://nas/volume1/media").absoluteString, "nfs://nas/volume1/media")
        XCTAssertEqual(try ShareURL.parse("cifs://nas/Public").absoluteString, "smb://nas/Public")
        XCTAssertEqual(try ShareURL.parse("smb://nas/Time%20Machine").absoluteString, "smb://nas/Time%20Machine")
    }

    func testExplicitUserOverridesEmbeddedUser() throws {
        XCTAssertEqual(try ShareURL.parse("smb://alice@nas/Public", user: "bob").absoluteString, "smb://bob@nas/Public")
    }

    func testAcceptsTheRootExportOfAnNFSServer() throws {
        XCTAssertEqual(try ShareURL.parse("nfs://nas/").absoluteString, "nfs://nas/")
        XCTAssertEqual(try ShareURL.parse("nas:/").absoluteString, "nfs://nas/")
    }

    func testRejectsInvalidTargets() {
        XCTAssertThrowsError(try ShareURL.parse(""))
        XCTAssertThrowsError(try ShareURL.parse("nas"))
        XCTAssertThrowsError(try ShareURL.parse("ftp://nas/files"))
        XCTAssertThrowsError(try ShareURL.parse("smb://nas"))
        XCTAssertThrowsError(try ShareURL.parse("smb://nas/"))
    }
}

final class IPv4SubnetTests: XCTestCase {
    func testParsesAndFormats() {
        let subnet = IPv4Subnet(cidr: "192.168.1.37/24")
        XCTAssertNotNil(subnet)
        XCTAssertEqual(subnet?.description, "192.168.1.0/24")
        XCTAssertEqual(IPv4Subnet.format(subnet!.broadcast), "192.168.1.255")
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.300/24"))
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/33"))
        XCTAssertNil(IPv4Subnet(cidr: "nas.local"))
    }

    func testHostAddressesOfA24() {
        let hosts = IPv4Subnet(cidr: "10.0.0.5/24")!.hostAddresses()
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(IPv4Subnet.format(hosts.first!), "10.0.0.1")
        XCTAssertEqual(IPv4Subnet.format(hosts.last!), "10.0.0.254")
    }

    func testLargeSubnetIsNarrowedAroundOwnAddress() {
        let hosts = IPv4Subnet(cidr: "172.16.42.7/16")!.hostAddresses(maxPrefix: 24)
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(IPv4Subnet.format(hosts.first!), "172.16.42.1")
    }

    func testSingleAddress() {
        let hosts = IPv4Subnet(cidr: "192.168.1.10")!.hostAddresses()
        XCTAssertEqual(hosts.map(IPv4Subnet.format), ["192.168.1.10"])
    }
}

final class ScannerMergeTests: XCTestCase {
    func testMergesSameAddressAndPutsNFSFirst() {
        let merged = NetworkScanner.merge([
            DiscoveredServer(address: "192.168.1.20", protocols: [.smb], sources: [.portScan]),
            DiscoveredServer(address: "192.168.1.10", bonjourName: "DiskStation", protocols: [.smb], sources: [.bonjour]),
            DiscoveredServer(address: "192.168.1.10", protocols: [.nfs], sources: [.portScan]),
            DiscoveredServer(address: "192.168.1.9", protocols: [.smb], sources: [.portScan]),
        ])
        XCTAssertEqual(merged.map(\.address), ["192.168.1.10", "192.168.1.9", "192.168.1.20"])
        XCTAssertEqual(merged[0].protocols, [.nfs, .smb])
        XCTAssertEqual(merged[0].sources, [.bonjour, .portScan])
        XCTAssertEqual(merged[0].displayName, "DiskStation")
    }
}

final class MountedShareTests: XCTestCase {
    func testExtractsServer() {
        XCTAssertEqual(MountedShare(kind: .nfs, source: "nas:/volume1/media", mountPoint: "/Volumes/media").server, "nas")
        XCTAssertEqual(MountedShare(kind: .smb, source: "//bob@nas._smb._tcp.local/Public", mountPoint: "/Volumes/Public").server, "nas._smb._tcp.local")
        XCTAssertEqual(MountedShares.kind(forFileSystemType: "smbfs"), .smb)
        XCTAssertNil(MountedShares.kind(forFileSystemType: "apfs"))
    }
}

final class MountPointTests: XCTestCase {
    func testRootIsAMountPointAndAPlainFolderIsNot() throws {
        #if os(macOS)
        XCTAssertTrue(MountedShares.isMountPoint("/"))
        XCTAssertFalse(MountedShares.isMountPoint("/Volumes/shareman-does-not-exist"))
        XCTAssertFalse(MountedShares.isMountPoint(NSTemporaryDirectory()))
        #endif
    }

    func testUnmountingSomethingNotMountedSaysSo() async {
        #if os(macOS)
        do {
            try await ShareMounter.unmount(path: "/Volumes/shareman-does-not-exist")
            XCTFail("unmount should have failed")
        } catch {
            XCTAssertEqual(
                error as? ShareManError,
                .unmountFailed(path: "/Volumes/shareman-does-not-exist", message: "rien n'est monté à cet endroit.")
            )
        }
        #endif
    }
}

final class PortScannerTests: XCTestCase {
    func testClosedLocalPortIsNotReported() {
        // Port 1 on loopback is closed on any normal machine: the connection is refused at once.
        let open = PortScanner.scanSync(hosts: [IPv4Subnet.parseAddress("127.0.0.1")!], ports: [1], timeout: 0.5)
        XCTAssertTrue(open.open.isEmpty)
    }
}

final class RPCPortmapperTests: XCTestCase {
    func testGetPortCallEncoding() {
        let call = RPCPortmapper.getPortCall(xid: 0x0102_0304, program: 100_003, version: 3, transport: 6)
        XCTAssertEqual(call.count, 56)
        XCTAssertEqual(Array(call[0..<4]), [1, 2, 3, 4])
        // Portmapper program 100000 = 0x000186A0, procedure 3.
        XCTAssertEqual(Array(call[12..<16]), [0x00, 0x01, 0x86, 0xA0])
        XCTAssertEqual(Array(call[20..<24]), [0, 0, 0, 3])
        // Asked program 100003 = 0x000186A3, version 3, TCP.
        XCTAssertEqual(Array(call[40..<44]), [0x00, 0x01, 0x86, 0xA3])
        XCTAssertEqual(Array(call[44..<48]), [0, 0, 0, 3])
        XCTAssertEqual(Array(call[48..<52]), [0, 0, 0, 6])
    }

    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { [UInt8($0 >> 24 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
    }

    func testParsesSuccessfulReply() {
        // xid, REPLY, MSG_ACCEPTED, verifier AUTH_NONE len 0, SUCCESS, port 2049
        let reply = words([42, 1, 0, 0, 0, 0, 2049])
        let parsed = RPCPortmapper.parseGetPortReply(reply)
        XCTAssertEqual(parsed?.xid, 42)
        XCTAssertEqual(parsed?.port, 2049)
    }

    func testParsesReplyWithVerifierBody() {
        // Verifier of 5 bytes is padded to 8.
        let reply = words([7, 1, 0, 1, 5, 0, 0, 0, 2049])
        XCTAssertEqual(RPCPortmapper.parseGetPortReply(reply)?.port, 2049)
    }

    func testRejectsDeniedOrTruncatedReplies() {
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 1, 1, 0, 0])))      // MSG_DENIED
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 0, 0, 0, 0, 0, 0]))) // a CALL, not a REPLY
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 1, 0, 0, 0, 1, 0]))) // PROG_UNAVAIL
        XCTAssertNil(RPCPortmapper.parseGetPortReply([0, 0, 0]))
    }
}

final class ScanOptionsTests: XCTestCase {
    func testDeepScanWidensSubnetsAndTimeouts() {
        var options = ScanOptions()
        options.subnets = [IPv4Subnet(cidr: "192.168.138.20/23")!, IPv4Subnet(cidr: "10.1.2.3/16")!]
        XCTAssertEqual(NetworkScanner.subnetsToScan(options).map(\.description), ["192.168.138.0/23", "10.1.0.0/22"])
        options.deepNFS = true
        XCTAssertEqual(NetworkScanner.subnetsToScan(options).map(\.description), ["192.168.138.0/23", "10.1.0.0/20"])
        XCTAssertGreaterThanOrEqual(options.effectiveTimeout, 1.5)
    }

    func testDeepScanWithoutNFSChangesNothing() {
        var options = ScanOptions()
        options.protocols = [.smb]
        options.deepNFS = true
        options.subnets = [IPv4Subnet(cidr: "10.1.2.3/16")!]
        XCTAssertEqual(NetworkScanner.subnetsToScan(options).map(\.description), ["10.1.0.0/22"])
        XCTAssertEqual(options.effectiveTimeout, options.connectTimeout)
    }

    func testWarnsWhenASubnetIsNarrowed() {
        var options = ScanOptions()
        options.subnets = [IPv4Subnet(cidr: "10.0.0.0/24")!]
        XCTAssertTrue(NetworkScanner.narrowingWarnings(options).isEmpty)
        options.subnets = [IPv4Subnet(cidr: "10.0.0.0/16")!, IPv4Subnet(cidr: "192.168.1.0/24")!]
        let warnings = NetworkScanner.narrowingWarnings(options)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("10.0.0.0/16"))
        XCTAssertTrue(warnings[0].contains("10.0.0.0/22"))
    }

    func testBlockedLocallyDetection() {
        var result = PortScanner.Result()
        result.probeCount = 4
        result.immediateFailures = [EHOSTUNREACH: 4]
        XCTAssertTrue(result.looksBlockedLocally)
        result.probeCount = 254
        result.immediateFailures = [EHOSTUNREACH: 252]
        XCTAssertTrue(result.looksBlockedLocally)
        result.immediateFailures = [EHOSTUNREACH: 120]
        XCTAssertFalse(result.looksBlockedLocally)
        result.immediateFailures = [EHOSTUNREACH: 252]
        result.open = [1: [2049]]
        XCTAssertFalse(result.looksBlockedLocally)
    }

    func testProbeCannotJudgeAHostName() async {
        // Only IPv4 addresses are probed: a name gives no verdict, not "silent".
        let answer = await NetworkScanner.probe(host: "nas.example.invalid")
        XCTAssertEqual(answer, .unknown)
        let protocols = await NetworkScanner.protocols(answeringOn: "nas.example.invalid")
        XCTAssertNil(protocols)
    }

    func testProbeOfALocalAddressWithoutFileSharing() async {
        // 127.0.0.2 is this machine and nobody listens there on the NFS and SMB ports.
        let answer = await NetworkScanner.probe(host: "127.0.0.2", timeout: 0.5)
        XCTAssertEqual(answer, .silent)
    }
}

final class FinderFavoritesPathTests: XCTestCase {
    func testNormalizedPathDropsTrailingSlashAndDots() {
        XCTAssertEqual(FinderFavorites.normalizedPath("/Volumes/media/"), "/Volumes/media")
        XCTAssertEqual(FinderFavorites.normalizedPath("/Volumes/./media//"), "/Volumes/media")
        XCTAssertEqual(FinderFavorites.normalizedPath("/"), "/")
    }

    func testNormalizedPathExpandsTilde() {
        XCTAssertEqual(FinderFavorites.normalizedPath("~"), FinderFavorites.normalizedPath(NSHomeDirectory()))
    }
}
