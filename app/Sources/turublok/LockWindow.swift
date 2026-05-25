import AppKit
import AVFoundation
import AVKit
import QuartzCore

/// View yang nge-intercept SEMUA mouse event, biar walaupun window transparan,
/// klik ga tembus ke desktop / app di belakang.
final class EventCaptureView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

final class LockWindow: NSWindow {
    private let screenRef: NSScreen
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var skipHintLayer: CATextLayer?

    init(screen: NSScreen) {
        self.screenRef = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.canHide = false
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        self.setFrame(screen.frame, display: true)

        let root = EventCaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.layer = CALayer()
        root.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func attachCat(videoURL: URL) async {
        await MainActor.run {
            let player = AVPlayer(url: videoURL)
            player.isMuted = true
            player.volume = 0
            player.actionAtItemEnd = .none

            self.player = player
            self.installPlayerLayer(player: player)

            if let item = player.currentItem {
                self.statusObserver = item.observe(\.status, options: [.new, .initial]) { observed, _ in
                    Log.info("AVPlayerItem status=\(observed.status.rawValue) error=\(String(describing: observed.error))")
                    if observed.status == .readyToPlay {
                        player.play()
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { _ in
                    player.seek(to: .zero)
                    player.play()
                }
            }
            player.play()
        }
    }

    private func installPlayerLayer(player: AVPlayer) {
        guard let root = contentView?.layer else { return }
        let layer = AVPlayerLayer(player: player)
        layer.frame = root.bounds
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(layer)
        self.playerLayer = layer
        Log.info("AVPlayerLayer added frame=\(layer.frame)")
    }

    func showSkipHint() {
        guard let root = contentView?.layer else { return }
        let hint = CATextLayer()
        hint.string = "Tahan  ESC  3  detik  untuk  skip  kali  ini  ·  trigger  berikutnya  ga  bisa  di-skip"
        hint.fontSize = 14
        hint.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        hint.alignmentMode = .center
        hint.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        hint.font = NSFont.systemFont(ofSize: 14, weight: .medium)

        let width: CGFloat = 800
        let height: CGFloat = 24
        hint.frame = CGRect(
            x: (root.bounds.width - width) / 2,
            y: 30,
            width: width,
            height: height
        )
        root.addSublayer(hint)
        self.skipHintLayer = hint
    }

    func teardown() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        orderOut(nil)
    }
}
