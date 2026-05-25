import Foundation

enum Sentinel {
    static let supportDir: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/turublok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var skipNextURL: URL { supportDir.appendingPathComponent("skip-next.flag") }
    static var pidfileURL: URL { supportDir.appendingPathComponent("lock.pid") }

    /// True kalau skip-next flag ada (install-time spurious launch). Konsumsi flag-nya juga.
    static func consumeSkipFlag() -> Bool {
        guard FileManager.default.fileExists(atPath: skipNextURL.path) else { return false }
        try? FileManager.default.removeItem(at: skipNextURL)
        return true
    }

    /// True kalau ada instance turublok lain yang masih hidup berdasarkan pidfile.
    static func anotherInstanceRunning() -> Bool {
        guard let data = try? Data(contentsOf: pidfileURL),
              let str = String(data: data, encoding: .utf8),
              let pid = Int32(str.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }

        if pid == ProcessInfo.processInfo.processIdentifier { return false }

        // kill(pid, 0) = signal 0 = cek apakah PID exist (ga benar-benar kirim sinyal)
        return kill(pid, 0) == 0
    }

    /// Write PID kita ke pidfile.
    static func acquirePidfile() {
        let pid = ProcessInfo.processInfo.processIdentifier
        try? Data("\(pid)\n".utf8).write(to: pidfileURL, options: .atomic)
    }

    static func releasePidfile() {
        try? FileManager.default.removeItem(at: pidfileURL)
    }
}
