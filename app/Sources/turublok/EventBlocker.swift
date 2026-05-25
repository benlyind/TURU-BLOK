import AppKit
import Carbon.HIToolbox
import CoreGraphics

final class EventBlocker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let blocker = Unmanaged<EventBlocker>.fromOpaque(refcon).takeUnretainedValue()
                return blocker.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.error("Failed to create CGEventTap — Accessibility permission required.")
            Log.error("Buka System Settings → Privacy & Security → Accessibility → enable 'turublok'")
            return
        }

        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("EventBlocker active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let opt = flags.contains(.maskAlternate)
        let ctrl = flags.contains(.maskControl)
        let fn = flags.contains(.maskSecondaryFn)

        if cmd && opt && keyCode == Int64(kVK_Escape) { return nil }   // Force Quit dialog
        if cmd && keyCode == Int64(kVK_ANSI_Q) { return nil }          // Cmd+Q
        if cmd && keyCode == Int64(kVK_ANSI_W) { return nil }          // Cmd+W
        if cmd && keyCode == Int64(kVK_ANSI_H) { return nil }          // Cmd+H
        if cmd && keyCode == Int64(kVK_ANSI_M) { return nil }          // Cmd+M
        if cmd && keyCode == Int64(kVK_Tab) { return nil }             // Cmd+Tab
        if cmd && keyCode == Int64(kVK_Space) { return nil }           // Spotlight
        if cmd && opt && keyCode == Int64(kVK_ANSI_D) { return nil }   // Toggle dock
        if cmd && opt && keyCode == Int64(kVK_Space) { return nil }    // Char picker

        if keyCode == Int64(kVK_F3) { return nil }                     // Mission Control
        if keyCode == Int64(kVK_F4) { return nil }                     // Launchpad
        if keyCode == Int64(kVK_F11) { return nil }                    // Show Desktop
        if keyCode == Int64(kVK_F12) { return nil }                    // Dashboard

        if ctrl && (keyCode == Int64(kVK_LeftArrow) ||
                    keyCode == Int64(kVK_RightArrow) ||
                    keyCode == Int64(kVK_UpArrow) ||
                    keyCode == Int64(kVK_DownArrow)) {
            return nil
        }

        if fn && (keyCode == Int64(kVK_F3) || keyCode == Int64(kVK_F4) ||
                  keyCode == Int64(kVK_F11) || keyCode == Int64(kVK_F12)) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
