import AppKit
import Foundation
import IOKit

/// Time-based fatigue watcher (Workrave style).
/// - Polling tiap N detik
/// - Cek HIDIdleTime: kalau user aktif (idle < 5 menit), accumulate work time
/// - Kalau workMin >= 60 → trigger fatigue lock
/// - Setelah trigger, cooldown 2 jam
///
/// Ga butuh kamera, ga butuh Vision. Reliable buat kasus pakai kacamata.
final class TimeWatcher {
    private let onTrigger: () -> Void
    private var workStart: Date?
    private var cooldownUntil: Date?
    private var pollTimer: Timer?
    private var debugCounter = 0

    private let pollIntervalSeconds: TimeInterval = 30

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        Log.info("TimeWatcher started (poll \(Int(pollIntervalSeconds))s, work threshold \(Int(FatigueConfig.minWorkSeconds))s, idle reset \(Int(FatigueConfig.awayResetSeconds))s)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
        tick()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        let now = Date()
        let idleSeconds = Self.getIdleSeconds()

        if let until = cooldownUntil, now < until {
            return
        } else if cooldownUntil != nil {
            cooldownUntil = nil
        }

        if idleSeconds > FatigueConfig.awayResetSeconds {
            workStart = nil
        } else if workStart == nil {
            workStart = now
        }

        debugCounter += 1
        if debugCounter % 4 == 0 {
            let workMin = workStart.map { Int(now.timeIntervalSince($0) / 60) } ?? 0
            Log.info("activity: workMin=\(workMin) idleSec=\(Int(idleSeconds))")
        }

        guard let start = workStart else { return }
        let workTime = now.timeIntervalSince(start)
        if workTime >= FatigueConfig.minWorkSeconds {
            Log.info("WORK-TIME TRIGGER: workTime=\(Int(workTime/60))min")
            cooldownUntil = now.addingTimeInterval(FatigueConfig.cooldownSeconds)
            workStart = nil
            DispatchQueue.main.async { self.onTrigger() }
        }
    }

    /// Detik sejak last keyboard/mouse activity, via IOHIDSystem service.
    static func getIdleSeconds() -> TimeInterval {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iter
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iter) }

        let service = IOIteratorNext(iter)
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = props["HIDIdleTime"] as? Int64
        else { return 0 }

        return TimeInterval(nanoseconds) / 1_000_000_000.0
    }
}
