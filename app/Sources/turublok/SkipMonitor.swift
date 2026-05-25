import AppKit
import Carbon.HIToolbox

/// Detect "ESC ditahan 3 detik" untuk skip fatigue-lock.
/// Pakai NSEvent local monitor (fire saat lock window active).
final class SkipMonitor {
    private let holdDurationSeconds: TimeInterval = 3.0
    private let onSkip: () -> Void

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var holdTimer: Timer?
    private var holdStart: Date?

    init(onSkip: @escaping () -> Void) {
        self.onSkip = onSkip
    }

    func start() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                self.startHold()
            }
            return event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelHold()
            }
            return event
        }
        Log.info("SkipMonitor active (tahan ESC \(Int(holdDurationSeconds)) detik buat skip)")
    }

    func stop() {
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
        if let m = keyUpMonitor { NSEvent.removeMonitor(m); keyUpMonitor = nil }
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func startHold() {
        holdTimer?.invalidate()
        holdStart = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdDurationSeconds, repeats: false) { [weak self] _ in
            Log.info("ESC held for \(self?.holdDurationSeconds ?? 0)s — SKIP triggered")
            self?.onSkip()
        }
        if let timer = holdTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func cancelHold() {
        if holdStart != nil {
            holdTimer?.invalidate()
            holdTimer = nil
            holdStart = nil
        }
    }
}
