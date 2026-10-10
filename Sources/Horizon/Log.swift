import Foundation

/// 写到 ~/Library/Logs/Horizon/horizon.log。应用没有主窗口，出问题时靠它排查。
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Horizon", isDirectory: true)
    static let url = directory.appendingPathComponent("horizon.log")
    private static let queue = DispatchQueue(label: "horizon.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 超过 512KB 就把旧的挪走，只保留一份
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
            let old = directory.appendingPathComponent("horizon.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 退出前等日志写完
    static func flush() { queue.sync {} }
}

func log(_ message: @autoclosure () -> String) { Log.write(message()) }
