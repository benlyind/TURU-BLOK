import Foundation

/// Konfig deteksi. Override pakai ENV TURUBLOK_TEST_FATIGUE=1 untuk testing.
enum FatigueConfig {
    static var isTestMode: Bool {
        ProcessInfo.processInfo.environment["TURUBLOK_TEST_FATIGUE"] == "1"
    }

    static var minWorkSeconds: TimeInterval {
        isTestMode ? 20 : 60 * 60       // 20s (test) / 1 jam (normal)
    }
    static var warningHoldSeconds: TimeInterval {
        isTestMode ? 5 : 30             // 5s (test) / 30s sustained drowsy
    }
    static var cooldownSeconds: TimeInterval {
        isTestMode ? 30 : 60 * 60 * 2   // 30s (test) / 2 jam (normal)
    }
    /// Ratio baseline yang dianggep drowsy (mata > 40% lebih tertutup dari normal kamu).
    static var drowsyRatioOfBaseline: Float {
        isTestMode ? 0.75 : 0.60        // 75% lebih sensitif buat test
    }
    /// Min samples sebelum baseline valid.
    static var calibrationMinSamples: Int {
        isTestMode ? 5 : 20             // 5 sample (test, ~25s) / 20 sample (normal, ~10 menit)
    }
    static let awayResetSeconds: TimeInterval = 5 * 60
    static var sampleIntervalSeconds: TimeInterval {
        isTestMode ? 5 : 30
    }
    static let analysisWindowSeconds: TimeInterval = 5 * 60
}

enum FatigueState: String {
    case idle
    case calibrating
    case present
    case away
    case warning
    case cooldown
}

/// Persistent baseline yang ke-calibrate per-user (survives restart).
struct EARBaseline: Codable {
    var value: Float
    var sampleCount: Int
    var lastUpdated: Date
}

enum BaselineStore {
    static let url: URL = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/turublok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ear_baseline.json")
    }()

    static func load() -> EARBaseline? {
        guard let data = try? Data(contentsOf: url),
              let baseline = try? JSONDecoder().decode(EARBaseline.self, from: data)
        else { return nil }
        return baseline
    }

    static func save(_ baseline: EARBaseline) {
        if let data = try? JSONEncoder().encode(baseline) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}

final class FatigueStateMachine {
    private(set) var state: FatigueState = .idle
    private(set) var workSessionStart: Date?
    private(set) var lastFaceSeen: Date?
    private(set) var warningStart: Date?
    private(set) var cooldownUntil: Date?
    private(set) var baseline: EARBaseline?

    private var earSamples: [(Date, Float)] = []
    private var calibrationSamples: [Float] = []

    init() {
        self.baseline = BaselineStore.load()
        if let b = baseline {
            Log.info("loaded EAR baseline=\(b.value) (n=\(b.sampleCount), last=\(b.lastUpdated))")
        } else {
            Log.info("no EAR baseline yet — will calibrate during first \(FatigueConfig.calibrationMinSamples) samples")
        }
    }

    /// Returns true kalau harus trigger fatigue lock SEKARANG.
    func update(now: Date, faceFound: Bool, earValue: Float?) -> Bool {
        // Cooldown wins
        if let until = cooldownUntil, now < until {
            state = .cooldown
            return false
        } else if cooldownUntil != nil {
            cooldownUntil = nil
        }

        if !faceFound {
            if let lastSeen = lastFaceSeen, now.timeIntervalSince(lastSeen) > FatigueConfig.awayResetSeconds {
                state = .away
                workSessionStart = nil
                warningStart = nil
                earSamples.removeAll()
            } else if lastFaceSeen == nil {
                state = .idle
            } else {
                state = .present
            }
            return false
        }

        lastFaceSeen = now
        if workSessionStart == nil {
            workSessionStart = now
        }

        // Calibration phase: kumpulin baseline kalau belum ada.
        if baseline == nil || (baseline?.sampleCount ?? 0) < FatigueConfig.calibrationMinSamples {
            if let ear = earValue {
                calibrationSamples.append(ear)
                state = .calibrating
                if calibrationSamples.count >= FatigueConfig.calibrationMinSamples {
                    let avg = calibrationSamples.reduce(0, +) / Float(calibrationSamples.count)
                    baseline = EARBaseline(
                        value: avg,
                        sampleCount: calibrationSamples.count,
                        lastUpdated: now
                    )
                    BaselineStore.save(baseline!)
                    Log.info("CALIBRATION COMPLETE: baseline EAR=\(avg) (n=\(calibrationSamples.count))")
                    calibrationSamples.removeAll()
                }
            }
            return false
        }

        // Normal monitoring
        if let ear = earValue {
            earSamples.append((now, ear))
            let cutoff = now.addingTimeInterval(-FatigueConfig.analysisWindowSeconds)
            earSamples.removeAll { $0.0 < cutoff }
        }

        guard let start = workSessionStart,
              now.timeIntervalSince(start) >= FatigueConfig.minWorkSeconds else {
            state = .present
            warningStart = nil
            return false
        }

        guard let baseline = baseline, earSamples.count >= 3 else {
            state = .present
            return false
        }

        let avgEAR = earSamples.map(\.1).reduce(0, +) / Float(earSamples.count)
        let threshold = baseline.value * FatigueConfig.drowsyRatioOfBaseline
        let isDrowsy = avgEAR < threshold

        if isDrowsy {
            if warningStart == nil {
                warningStart = now
                state = .warning
                Log.info("fatigue WARNING: avgEAR=\(avgEAR) threshold=\(threshold) (baseline=\(baseline.value))")
            }
            if let warn = warningStart,
               now.timeIntervalSince(warn) >= FatigueConfig.warningHoldSeconds {
                Log.info("FATIGUE TRIGGERED: avgEAR=\(avgEAR) workTime=\(Int(now.timeIntervalSince(start)/60))min")
                cooldownUntil = now.addingTimeInterval(FatigueConfig.cooldownSeconds)
                warningStart = nil
                workSessionStart = now
                earSamples.removeAll()
                state = .cooldown
                return true
            }
        } else {
            warningStart = nil
            state = .present
        }
        return false
    }

    var debugDescription: String {
        let avgEAR: Float = earSamples.isEmpty
            ? 0
            : earSamples.map(\.1).reduce(0, +) / Float(earSamples.count)
        let workMin = workSessionStart.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        let baselineStr = baseline.map { String(format: "%.3f", $0.value) } ?? "n/a"
        return "state=\(state.rawValue) workMin=\(workMin) baseline=\(baselineStr) avgEAR=\(String(format: "%.3f", avgEAR)) samples=\(earSamples.count) calib=\(calibrationSamples.count)"
    }
}
