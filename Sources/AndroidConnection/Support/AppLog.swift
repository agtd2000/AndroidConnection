import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "com.androidconnection.applog")

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("Logs/AndroidConnection", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("androidconnection.log")
    }

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
