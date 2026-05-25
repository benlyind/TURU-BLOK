import AppKit
import AVFoundation
import CoreMedia
import Vision

/// Periodically buka kamera ~1 detik, ambil 1 frame, tutup. Bukan continuous capture.
/// Berarti lampu kamera kedip-kedip tiap N detik, bukan terus nyala.
final class EyeWatcher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "turublok.eyewatch.analysis")

    private let stateMachine = FatigueStateMachine()
    private let onTrigger: () -> Void

    private var cycleTimer: Timer?
    private var safetyTimer: Timer?
    private var inCaptureWindow = false
    private var frameCountThisWindow = 0
    private var debugLogCounter = 0

    /// Berapa frame yang di-skip pas kamera baru nyala (buat auto-exposure stabilize).
    private let warmupFrames = 3
    /// Max berapa lama kamera boleh nyala per cycle (safety).
    private let maxCaptureWindowSeconds: TimeInterval = 2.0

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        super.init()
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureSession()
            beginCycle()
        case .notDetermined:
            Log.info("requesting Camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.configureSession()
                        self?.beginCycle()
                    }
                } else {
                    Log.error("Camera permission denied — eye-watch feature disabled")
                }
            }
        case .denied, .restricted:
            Log.error("Camera permission denied/restricted. Enable di System Settings → Privacy & Security → Camera")
        @unknown default:
            Log.error("Unknown camera authorization status: \(status.rawValue)")
        }
    }

    func stop() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            Log.error("no video capture device available")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            Log.error("can't create AVCaptureDeviceInput")
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.commitConfiguration()

        Log.info("EyeWatcher: camera cycle aktif (\(Int(FatigueConfig.sampleIntervalSeconds))s OFF, ~1s ON per cycle)")
    }

    private func beginCycle() {
        // Capture pertama immediate, lalu schedule berkala.
        beginCaptureWindow()
    }

    private func scheduleNextWindow() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: FatigueConfig.sampleIntervalSeconds, repeats: false) { [weak self] _ in
            self?.beginCaptureWindow()
        }
        if let t = cycleTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func beginCaptureWindow() {
        guard !inCaptureWindow else { return }
        inCaptureWindow = true
        frameCountThisWindow = 0
        captureSession.startRunning()

        // Safety: kalau ga dapet frame dalam 2 detik, paksa tutup.
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: maxCaptureWindowSeconds, repeats: false) { [weak self] _ in
            Log.warn("capture window timeout — no usable frame")
            self?.endCaptureWindow()
        }
        if let t = safetyTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func endCaptureWindow() {
        guard inCaptureWindow else { return }
        inCaptureWindow = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        scheduleNextWindow()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard inCaptureWindow else { return }
        frameCountThisWindow += 1
        guard frameCountThisWindow > warmupFrames else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()

        let request = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            self?.handleVisionResult(req: req, now: now)
            DispatchQueue.main.async { self?.endCaptureWindow() }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleVisionResult(req: VNRequest, now: Date) {
        let observations = (req.results as? [VNFaceObservation]) ?? []

        if observations.isEmpty {
            if stateMachine.update(now: now, faceFound: false, earValue: nil) {
                DispatchQueue.main.async { self.onTrigger() }
            }
            logDebug()
            return
        }

        let face = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width })!
        let leftEAR = computeEAR(from: face.landmarks?.leftEye)
        let rightEAR = computeEAR(from: face.landmarks?.rightEye)
        let avgEAR: Float? = {
            switch (leftEAR, rightEAR) {
            case let (l?, r?): return (l + r) / 2
            case let (l?, nil): return l
            case let (nil, r?): return r
            case (nil, nil): return nil
            }
        }()

        if stateMachine.update(now: now, faceFound: true, earValue: avgEAR) {
            DispatchQueue.main.async { self.onTrigger() }
        }
        logDebug()
    }

    private func logDebug() {
        debugLogCounter += 1
        if debugLogCounter % 5 == 0 {
            Log.info("eye sample: \(stateMachine.debugDescription)")
        }
    }

    private func computeEAR(from region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let region = region else { return nil }
        let points = region.normalizedPoints
        if points.count >= 6 {
            let p1 = points[0], p2 = points[1], p3 = points[2]
            let p4 = points[3], p5 = points[4], p6 = points[5]
            let vertical = distance(p2, p6) + distance(p3, p5)
            let horizontal = 2 * distance(p1, p4)
            guard horizontal > 0.001 else { return nil }
            return Float(vertical / horizontal)
        } else if points.count >= 4 {
            let xs = points.map { Float($0.x) }
            let ys = points.map { Float($0.y) }
            let width = (xs.max() ?? 0) - (xs.min() ?? 0)
            let height = (ys.max() ?? 0) - (ys.min() ?? 0)
            guard width > 0.001 else { return nil }
            return height / width
        }
        return nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}
