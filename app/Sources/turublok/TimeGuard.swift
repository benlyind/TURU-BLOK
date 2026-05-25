import Foundation

struct LockState: Codable {
    var startedAt: Date
    var targetEndAt: Date
    var lastSeenAt: Date
    var remainingSeconds: Double
}

final class TimeGuard {
    private let stateURL: URL
    private(set) var state: LockState
    private let lockConfig: LockConfig
    private let testDuration: Int?

    private let suspiciousForwardJumpSec: TimeInterval = 300   // > 5 menit ke depan = curiga
    private let suspiciousBackwardJumpSec: TimeInterval = 60   // > 1 menit mundur = curiga
    private let normalTickBudgetSec: TimeInterval = 2

    init(lockConfig: LockConfig, fixedDurationSeconds: Int? = nil, stateFilename: String = "state.json") {
        self.lockConfig = lockConfig
        self.testDuration = fixedDurationSeconds

        let support = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/turublok", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.stateURL = support.appendingPathComponent(stateFilename)

        let now = Date()

        // Fixed-duration mode (test, fatigue): resume kalau state masih hidup, else create new.
        if let fixedSec = fixedDurationSeconds {
            if let loaded = Self.load(from: stateURL),
               loaded.remainingSeconds > 0,
               loaded.targetEndAt > now {
                self.state = loaded
                Log.info("resumed fixed-duration state from \(stateFilename), remaining=\(Int(loaded.remainingSeconds))s")
            } else {
                let end = now.addingTimeInterval(TimeInterval(fixedSec))
                self.state = LockState(
                    startedAt: now,
                    targetEndAt: end,
                    lastSeenAt: now,
                    remainingSeconds: TimeInterval(fixedSec)
                )
                try? Self.persist(state, to: stateURL)
            }
            return
        }

        // Window-based mode (bedtime lock).
        if let loaded = Self.load(from: stateURL),
           loaded.remainingSeconds > 0,
           loaded.targetEndAt > now.addingTimeInterval(-3600) {
            self.state = loaded
            Log.info("loaded existing lock state, remaining=\(Int(loaded.remainingSeconds))s")
        } else {
            let end = lockConfig.nextEndDate(from: now)
            let remaining = end.timeIntervalSince(now)
            self.state = LockState(
                startedAt: now,
                targetEndAt: end,
                lastSeenAt: now,
                remainingSeconds: remaining
            )
            try? Self.persist(state, to: stateURL)
            Log.info("created new lock state, remaining=\(Int(remaining))s")
        }
    }

    /// Returns true jika lock harus terus berlanjut, false jika boleh unlock.
    func tick() -> Bool {
        let now = Date()

        // HARD CHECK: kalau bedtime lock (bukan fixed-duration) dan sekarang di LUAR window → unlock.
        // Ini nangkep kasus: laptop ditutup saat lock aktif, dibuka lagi setelah 07:00 → langsung unlock.
        if testDuration == nil && !lockConfig.isWithinLockWindow(now) {
            Log.info("now outside lock window — unlocking (wall-clock override)")
            return false
        }

        // HARD CHECK: kalau sekarang udah lewat targetEndAt → unlock (termasuk setelah sleep).
        if now > state.targetEndAt {
            Log.info("past targetEndAt — unlocking (wall-clock override)")
            return false
        }

        let delta = now.timeIntervalSince(state.lastSeenAt)

        if delta > suspiciousForwardJumpSec {
            // Forward jump: bisa laptop sleep atau tampering.
            // Karena sudah ada hard-check di atas, aman untuk decrement normal.
            Log.info("forward time jump \(Int(delta))s — adjusting remaining normally (hard checks passed)")
            state.remainingSeconds -= delta
            state.lastSeenAt = now
        } else if delta < -suspiciousBackwardJumpSec {
            Log.warn("BACKWARD time jump detected: \(Int(delta))s — keeping last seen, decrementing 1s only")
            state.remainingSeconds -= 1
        } else {
            let progress = max(min(delta, normalTickBudgetSec), 0.5)
            state.remainingSeconds -= progress
            state.lastSeenAt = now
        }

        try? Self.persist(state, to: stateURL)

        if state.remainingSeconds <= 0 {
            Log.info("lock duration completed, unlocking")
            return false
        }
        return true
    }

    func clearState() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    private static func persist(_ state: LockState, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> LockState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(LockState.self, from: data)
    }
}
