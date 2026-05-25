import Foundation

enum Log {
    static let logURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Projects/TURU-BLOK/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("turublok.log")
    }()

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ msg: String) {
        write(level: "INFO", msg)
    }

    static func warn(_ msg: String) {
        write(level: "WARN", msg)
    }

    static func error(_ msg: String) {
        write(level: "ERROR", msg)
    }

    private static func write(level: String, _ msg: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
