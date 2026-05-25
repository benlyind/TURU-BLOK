import AppKit
import Foundation

enum LockMode {
    case lock
    case fatigue(durationSeconds: Int, skippable: Bool)
    case test(durationSeconds: Int)

    var stateFilename: String {
        switch self {
        case .lock: return "state.json"
        case .fatigue: return "fatigue_state.json"
        case .test: return "test_state.json"
        }
    }

    var skippable: Bool {
        if case .fatigue(_, let s) = self { return s }
        return false
    }
}

final class LockController: NSObject {
    private let mode: LockMode
    private var windows: [LockWindow] = []
    private let eventBlocker = EventBlocker()
    private var timeGuard: TimeGuard?
    private var ticker: Timer?
    private var cursorHidden = false
    private var skipMonitor: SkipMonitor?
    private var skipUsed = false

    init(mode: LockMode) {
        self.mode = mode
    }

    func start() {
        installSignalHandlers()

        let cfg = LockConfig.current()
        switch mode {
        case .lock:
            timeGuard = TimeGuard(lockConfig: cfg, stateFilename: mode.stateFilename)
        case .fatigue(let seconds, _):
            timeGuard = TimeGuard(lockConfig: cfg, fixedDurationSeconds: seconds, stateFilename: mode.stateFilename)
        case .test(let seconds):
            timeGuard = TimeGuard(lockConfig: cfg, fixedDurationSeconds: seconds, stateFilename: mode.stateFilename)
        }

        spawnWindows()
        Task { await loadVideoIntoWindows() }

        eventBlocker.start()
        hideCursor()

        if mode.skippable {
            let monitor = SkipMonitor { [weak self] in
                self?.skipUsed = true
                self?.gracefulExit()
            }
            monitor.start()
            self.skipMonitor = monitor
            for win in windows {
                win.showSkipHint()
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let ticker = ticker {
            RunLoop.main.add(ticker, forMode: .common)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func spawnWindows() {
        for screen in NSScreen.screens {
            let win = LockWindow(screen: screen)
            win.makeKeyAndOrderFront(nil)
            windows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadVideoIntoWindows() async {
        guard let videoURL = locateVideoFile() else {
            Log.warn("no video found in assets/, lock screen will be plain black")
            return
        }
        Log.info("using video: \(videoURL.path)")
        for win in windows {
            await win.attachCat(videoURL: videoURL)
        }
    }

    private func locateVideoFile() -> URL? {
        let assetsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/TURU-BLOK/assets", isDirectory: true)
        let exts = ["mp4", "mov", "m4v"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: assetsDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return contents.first { exts.contains($0.pathExtension.lowercased()) }
    }

    @objc private func screensChanged() {
        Log.info("screen configuration changed, respawning windows")
        for win in windows { win.teardown() }
        windows.removeAll()
        spawnWindows()
        Task { await loadVideoIntoWindows() }
    }

    private func tick() {
        guard let guardian = timeGuard else { return }
        let shouldContinue = guardian.tick()
        if !shouldContinue {
            gracefulExit()
        }
    }

    private func gracefulExit() {
        Log.info("graceful exit triggered (skipUsed=\(skipUsed))")
        ticker?.invalidate()
        ticker = nil
        eventBlocker.stop()
        skipMonitor?.stop()
        skipMonitor = nil
        showCursor()
        for win in windows { win.teardown() }
        windows.removeAll()
        timeGuard?.clearState()

        // Alternating skip: setiap kali fatigue-lock kelar (skip OR natural),
        // toggle state biar next trigger bergantian skippable / forced.
        if case .fatigue = mode {
            SkipStateStore.toggle()
        }
        exit(0)
    }

    private func hideCursor() {
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func showCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    private func installSignalHandlers() {
        // Ignore terminate signals — kita ga mau user 'kill <pid>' shutdown app sebelum waktunya.
        // SIGKILL ga bisa di-handle, tapi launchd KeepAlive akan restart.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
    }
}
