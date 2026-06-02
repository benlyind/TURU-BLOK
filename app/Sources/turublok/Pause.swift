import Foundation

/// Snooze mechanism: pause semua lock (bedtime + fatigue) sampai tanggal tertentu.
/// Agent tetep loaded di launchd, tapi tiap trigger cek file ini dulu — kalau masih
/// dalam periode pause, exit clean. Begitu lewat pause, otomatis aktif lagi.
enum PauseControl {
    static let url: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/turublok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pause_until.txt")
    }()

    /// True kalau sekarang masih dalam periode pause.
    static func isPaused(now: Date) -> Bool {
        guard let until = pausedUntil() else { return false }
        return now < until
    }

    static func pausedUntil() -> Date? {
        guard let str = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func setPause(until date: Date) {
        let str = ISO8601DateFormatter().string(from: date)
        try? str.write(to: url, atomically: true, encoding: .utf8)
        Log.info("PAUSE set until \(str)")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        Log.info("PAUSE cleared")
    }
}
