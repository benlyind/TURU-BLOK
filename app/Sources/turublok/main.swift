import AppKit
import Foundation

enum Mode {
    case lock
    case fatigueLock
    case watchEyes
    case debugEyes
    case test(durationSeconds: Int)
    case status
}

func parseArgs() -> Mode {
    let args = CommandLine.arguments.dropFirst()
    var mode: Mode = .lock

    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--lock":
            mode = .lock
        case "--fatigue-lock":
            mode = .fatigueLock
        case "--watch-eyes":
            mode = .watchEyes
        case "--debug-eyes":
            mode = .debugEyes
        case "--test":
            let next = iterator.next() ?? "30"
            mode = .test(durationSeconds: Int(next) ?? 30)
        case "--status":
            mode = .status
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        }
    }
    return mode
}

func printStatus() {
    let cfg = LockConfig.current()
    let now = Date()
    let inWindow = cfg.isWithinLockWindow(now)
    print("now:                  \(now)")
    print("bedtime window:       \(cfg.startHour):00 - \(cfg.endHour):00 (\(cfg.timezone.identifier))")
    print("currently in window:  \(inWindow)")
    if inWindow {
        let end = cfg.nextEndDate(from: now)
        print("ends at:              \(end)")
        print("seconds left:         \(Int(end.timeIntervalSince(now)))")
    } else {
        let start = cfg.nextStartDate(from: now)
        print("next bedtime start:   \(start)")
    }
    let skipState = SkipStateStore.load()
    print("next fatigue trigger: \(skipState.nextSkippable ? "SKIPPABLE (tahan ESC 3 detik)" : "FORCED (ga bisa skip)")")
}

func spawnFatigueLock() {
    let binaryPath = CommandLine.arguments[0]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["--fatigue-lock"]
    do {
        try process.run()
        Log.info("spawned fatigue-lock process pid=\(process.processIdentifier)")
    } catch {
        Log.error("failed to spawn fatigue-lock: \(error)")
    }
}

let mode = parseArgs()

switch mode {
case .status:
    printStatus()
    exit(0)

case .test(let seconds):
    Log.info("starting TEST mode for \(seconds) seconds")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = LockController(mode: .test(durationSeconds: seconds))
    controller.start()
    app.run()

case .lock:
    if Sentinel.consumeSkipFlag() {
        Log.info("skip-next flag found, exiting cleanly (install-time spurious launch)")
        exit(0)
    }
    if Sentinel.anotherInstanceRunning() {
        Log.info("another turublok already running, exiting cleanly")
        exit(0)
    }
    let cfg = LockConfig.current()
    let now = Date()
    guard cfg.isWithinLockWindow(now) else {
        Log.info("not within lock window, exiting cleanly")
        exit(0)
    }
    Sentinel.acquirePidfile()
    atexit { Sentinel.releasePidfile() }
    Log.info("starting LOCK mode (pid=\(ProcessInfo.processInfo.processIdentifier))")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = LockController(mode: .lock)
    controller.start()
    app.run()

case .fatigueLock:
    if Sentinel.anotherInstanceRunning() {
        Log.info("another lock instance running, fatigue-lock skipped")
        exit(0)
    }
    Sentinel.acquirePidfile()
    atexit { Sentinel.releasePidfile() }
    let skipState = SkipStateStore.load()
    Log.info("starting FATIGUE-LOCK (10 menit) skippable=\(skipState.nextSkippable)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = LockController(mode: .fatigue(durationSeconds: 600, skippable: skipState.nextSkippable))
    controller.start()
    app.run()

case .watchEyes:
    Log.info("starting WATCH-EYES mode (time-based, no camera)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let watcher = TimeWatcher {
        Log.info("FATIGUE TRIGGER received from TimeWatcher → spawning fatigue lock")
        spawnFatigueLock()
    }
    watcher.start()
    app.run()

case .debugEyes:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let debug = EyeDebug()
    debug.runAndExit()
}
