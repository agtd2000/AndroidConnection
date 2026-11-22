import Foundation

enum RemotePath {
    static func join(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return "/" }
        if index == trimmed.startIndex { return "/" }
        return String(trimmed[..<index])
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

enum FileListingParser {
    private static let longPattern = #"^([bcdlps-][rwxsStT-]{9}\S*)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.*)$"#
    private static let date = DateFormatter()

    static func parse(_ output: String, base: String) -> [FileItem] {
        date.dateFormat = "yyyy-MM-dd HH:mm"
        var result: [FileItem] = []
        let regex = try? NSRegularExpression(pattern: longPattern)

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else { continue }

            guard let regex,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  match.numberOfRanges == 9 else { continue }

            func group(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: line) else { return "" }
                return String(line[range])
            }

            let permissions = group(1)
            let size = Int64(group(5)) ?? 0
            var name = group(8)
            let modified = date.date(from: "\(group(6)) \(group(7))")
            let isDirectory = permissions.hasPrefix("d")
            let isSymlink = permissions.hasPrefix("l")

            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }

            result.append(FileItem(
                path: RemotePath.join(base, name),
                name: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: size,
                modified: modified,
                permissions: permissions
            ))
        }
        return result
    }
}
