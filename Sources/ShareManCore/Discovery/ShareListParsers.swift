import Foundation

/// Parses the output of `showmount -e <host>`:
///
///     Exports list on 192.168.1.10:
///     /volume1/media                     192.168.1.0/24
///     /volume1/backup                    Everyone
public enum ShowmountParser {
    public struct Export: Hashable, Sendable {
        public let path: String
        public let clients: [String]
    }

    /// `showmount` prints the path with `%-35s`, then a space, then the clients.
    private static let pathColumnWidth = 35

    public static func parse(_ output: String) -> [Export] {
        var exports: [Export] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("/") else { continue } // Skips the "Exports list on ..." header.
            let (path, clients) = splitAtClientColumn(line) ?? splitAtFirstSpace(line)
            guard !path.isEmpty else { continue }
            exports.append(Export(
                path: path,
                clients: clients.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            ))
        }
        return exports
    }

    /// A path shorter than its column is padded up to the clients: cutting at
    /// the column keeps a path that contains spaces ("/volume1/Mes films") whole.
    private static func splitAtClientColumn(_ line: String) -> (path: String, clients: String)? {
        let characters = Array(line)
        guard characters.count > pathColumnWidth,
              characters[pathColumnWidth - 1] == " ", characters[pathColumnWidth] == " "
        else { return nil }
        let path = String(characters[..<pathColumnWidth]).trimmingCharacters(in: .whitespaces)
        return (path, String(characters[pathColumnWidth...]))
    }

    /// A path that fills or overflows its column is followed by a single space.
    private static func splitAtFirstSpace(_ line: String) -> (path: String, clients: String) {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (line, "") }
        return (String(line[..<space]), String(line[space...]))
    }
}

/// Parses the output of `smbutil view //host`:
///
///     Share                                           Type    Comments
///     -------------------------------
///     Public                                          Disk
///     Time Machine                                    Disk    Backups
///     IPC$                                            Pipe    IPC Service (Samba 4.15)
///
///     3 shares listed
public enum SmbutilParser {
    public struct Share: Hashable, Sendable {
        public let name: String
        public let type: String
        public let comment: String?

        /// Administrative/hidden shares such as `IPC$`, `ADMIN$` or `C$`.
        public var isHidden: Bool { name.hasSuffix("$") }
        public var isDisk: Bool { type.caseInsensitiveCompare("Disk") == .orderedSame }
    }

    private static let knownTypes = ["Disk", "Pipe", "Printer", "Device", "Comm"]

    /// `smbutil view` prints each row as `%-48s%-8s%s`.
    private static let nameColumnWidth = 48

    /// Fallback for rows whose name overflows its column.
    private static let rowPattern = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(Disk|Pipe|Printer|Device|Comm)(?:\s+(.*))?$"#,
        options: [.caseInsensitive]
    )

    private typealias Row = (name: String, type: String, comment: String?)

    /// Splits a row at the type column. This is what keeps a share called
    /// "USB Disk 1" whole: its name contains a word that is also a type.
    private static func splitAtTypeColumn(_ line: String) -> Row? {
        // The column is counted in bytes, or in characters by newer versions.
        let utf8 = Array(line.utf8)
        var candidates: [(name: String, rest: String)] = []
        if utf8.count > nameColumnWidth,
           let name = String(bytes: utf8[..<nameColumnWidth], encoding: .utf8),
           let rest = String(bytes: utf8[nameColumnWidth...], encoding: .utf8) {
            candidates.append((name, rest))
        }
        if line.count > nameColumnWidth {
            candidates.append((String(line.prefix(nameColumnWidth)), String(line.dropFirst(nameColumnWidth))))
        }
        for candidate in candidates {
            let fields = candidate.rest.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            let name = candidate.name.trimmingCharacters(in: .whitespaces)
            guard !candidate.rest.hasPrefix(" "), !name.isEmpty,
                  let type = fields.first.map(String.init),
                  knownTypes.contains(where: { $0.caseInsensitiveCompare(type) == .orderedSame })
            else { continue }
            let comment = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
            return (name, type, comment.isEmpty ? nil : comment)
        }
        return nil
    }

    private static func splitWithPattern(_ line: String) -> Row? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = rowPattern.firstMatch(in: line, range: range),
              let nameRange = Range(match.range(at: 1), in: line),
              let typeRange = Range(match.range(at: 2), in: line)
        else { return nil }
        var comment: String?
        if let commentRange = Range(match.range(at: 3), in: line) {
            let text = line[commentRange].trimmingCharacters(in: .whitespaces)
            comment = text.isEmpty ? nil : text
        }
        return (line[nameRange].trimmingCharacters(in: .whitespaces), String(line[typeRange]), comment)
    }

    public static func parse(_ output: String) -> [Share] {
        var shares: [Share] = []
        var inTable = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !inTable {
                if line.hasPrefix("---") { inTable = true }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasSuffix("shares listed") || trimmed.hasSuffix("share listed") {
                continue
            }
            guard let row = splitAtTypeColumn(line) ?? splitWithPattern(line) else { continue }
            shares.append(Share(name: row.name, type: row.type, comment: row.comment))
        }
        return shares
    }
}
