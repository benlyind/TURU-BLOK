import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Vision

/// Single-shot debug: capture 1 frame webcam, run Vision, gambar landmark di frame, save PNG.
/// Output JSON ke stdout buat consumption otomatis.
final class EyeDebug: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "turublok.debug")
    private var frameCount = 0
    private let warmupFrames = 5
    private let outputPath: String

    init(outputPath: String = "/tmp/turublok_eye_debug.png") {
        self.outputPath = outputPath
        super.init()
    }

    func runAndExit() -> Never {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configure()
            captureSession.startRunning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.configure()
                        self?.captureSession.startRunning()
                    }
                } else {
                    FileHandle.standardError.write(Data("Camera permission denied\n".utf8))
                    exit(1)
                }
            }
        default:
            FileHandle.standardError.write(Data("Camera permission not available\n".utf8))
            exit(1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            FileHandle.standardError.write(Data("Timeout — no usable frame within 5s\n".utf8))
            exit(2)
        }

        RunLoop.main.run()
        exit(0)
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            FileHandle.standardError.write(Data("can't open camera\n".utf8))
            exit(1)
        }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        captureSession.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameCount += 1
        guard frameCount > warmupFrames else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceLandmarksRequest { [weak self] req, err in
            self?.handleResult(req: req, err: err, pixelBuffer: pixelBuffer)
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func handleResult(req: VNRequest, err: Error?, pixelBuffer: CVPixelBuffer) {
        captureSession.stopRunning()

        let observations = (req.results as? [VNFaceObservation]) ?? []

        var report: [String: Any] = [
            "frame_seq": frameCount,
            "face_count": observations.count,
        ]

        guard let face = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            report["error"] = "no face detected"
            saveReport(report, image: imageFromBuffer(pixelBuffer, drawnFace: nil, leftEye: nil, rightEye: nil))
            DispatchQueue.main.async { exit(0) }
            return
        }

        let leftEyePts = face.landmarks?.leftEye?.normalizedPoints ?? []
        let rightEyePts = face.landmarks?.rightEye?.normalizedPoints ?? []

        let leftEAR = computeEAR(from: face.landmarks?.leftEye)
        let rightEAR = computeEAR(from: face.landmarks?.rightEye)

        report["face_bbox"] = [
            "x": face.boundingBox.minX,
            "y": face.boundingBox.minY,
            "w": face.boundingBox.width,
            "h": face.boundingBox.height,
        ]
        report["left_eye_points"] = leftEyePts.map { ["x": $0.x, "y": $0.y] }
        report["right_eye_points"] = rightEyePts.map { ["x": $0.x, "y": $0.y] }
        report["left_ear"] = leftEAR ?? -1
        report["right_ear"] = rightEAR ?? -1
        report["avg_ear"] = avgEAR(leftEAR, rightEAR) ?? -1
        report["drowsy_threshold_fixed"] = 0.20
        report["recommendation"] = recommend(baseline: avgEAR(leftEAR, rightEAR))

        let image = imageFromBuffer(
            pixelBuffer,
            drawnFace: face.boundingBox,
            leftEye: leftEyePts,
            rightEye: rightEyePts
        )
        saveReport(report, image: image)
        DispatchQueue.main.async { exit(0) }
    }

    private func recommend(baseline: Float?) -> String {
        guard let b = baseline else { return "no EAR data" }
        let recommended = b * 0.70
        return String(format: "baseline=%.3f → drowsy threshold should be ~%.3f (0.70x baseline)", b, recommended)
    }

    private func avgEAR(_ l: Float?, _ r: Float?) -> Float? {
        switch (l, r) {
        case let (a?, b?): return (a + b) / 2
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    private func computeEAR(from region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let region = region else { return nil }
        let pts = region.normalizedPoints
        guard pts.count >= 6 else { return nil }
        let p1 = pts[0], p2 = pts[1], p3 = pts[2]
        let p4 = pts[3], p5 = pts[4], p6 = pts[5]
        let vertical = dist(p2, p6) + dist(p3, p5)
        let horizontal = 2 * dist(p1, p4)
        guard horizontal > 0.001 else { return nil }
        return Float(vertical / horizontal)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return sqrt(dx*dx + dy*dy)
    }

    /// Render frame jadi NSImage dengan landmark di-overlay.
    private func imageFromBuffer(_ buffer: CVPixelBuffer,
                                 drawnFace: CGRect?,
                                 leftEye: [CGPoint]?,
                                 rightEye: [CGPoint]?) -> NSImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ci, from: ci.extent) else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = 4 * width
        guard let cg = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Vision normalized coords: (0,0) bottom-left, y-up. CGContext also y-up. OK.
        if let bbox = drawnFace {
            let rect = CGRect(
                x: bbox.minX * CGFloat(width),
                y: bbox.minY * CGFloat(height),
                width: bbox.width * CGFloat(width),
                height: bbox.height * CGFloat(height)
            )
            cg.setStrokeColor(NSColor.systemYellow.cgColor)
            cg.setLineWidth(2)
            cg.stroke(rect)

            // Landmark points are normalized to the bbox, not the whole image.
            if let pts = leftEye {
                drawPoints(pts, in: cg, faceBBox: rect, color: .systemRed, label: "L")
            }
            if let pts = rightEye {
                drawPoints(pts, in: cg, faceBBox: rect, color: .systemCyan, label: "R")
            }
        }

        guard let outCG = cg.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: width, height: height))
    }

    private func drawPoints(_ pts: [CGPoint], in ctx: CGContext, faceBBox: CGRect, color: NSColor, label: String) {
        ctx.setFillColor(color.cgColor)
        for (idx, p) in pts.enumerated() {
            // Vision landmark normalized to faceBBox.
            let x = faceBBox.minX + p.x * faceBBox.width
            let y = faceBBox.minY + p.y * faceBBox.height
            let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            ctx.fillEllipse(in: dot)

            // Index label
            let _ = idx  // could draw index but skip for clarity
        }
    }

    private func saveReport(_ report: [String: Any], image: NSImage?) {
        // JSON to stdout
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]),
           let str = String(data: json, encoding: .utf8) {
            print(str)
        }

        // Save PNG
        guard let image = image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render PNG\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
            FileHandle.standardError.write(Data("saved \(outputPath)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("PNG write failed: \(error)\n".utf8))
        }
    }
}
