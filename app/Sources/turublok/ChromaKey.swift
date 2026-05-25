import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreImage.CIFilterBuiltins

enum ChromaKey {
    /// Bangun cube data 64x64x64 yang ngubah piksel hijau jadi transparan.
    /// Range hue HSV ~ 80°-160° dengan saturation > 0.3 dianggap "green screen".
    static func greenScreenCubeData(size: Int = 64) -> Data {
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        for z in 0..<size {
            let b = Float(z) / Float(size - 1)
            for y in 0..<size {
                let g = Float(y) / Float(size - 1)
                for x in 0..<size {
                    let r = Float(x) / Float(size - 1)
                    let (h, s, v) = rgbToHsv(r: r, g: g, b: b)
                    let isGreen = (h >= 75 && h <= 165) && s >= 0.30 && v >= 0.20
                    let alpha: Float = isGreen ? 0 : 1
                    let i = 4 * (x + y * size + z * size * size)
                    cube[i + 0] = r * alpha
                    cube[i + 1] = g * alpha
                    cube[i + 2] = b * alpha
                    cube[i + 3] = alpha
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func makeFilter() -> CIFilter? {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")
        filter?.setValue(64, forKey: "inputCubeDimension")
        filter?.setValue(greenScreenCubeData(), forKey: "inputCubeData")
        filter?.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")
        return filter
    }

    static func makeVideoComposition(for asset: AVAsset) async -> AVVideoComposition? {
        guard let filter = makeFilter() else { return nil }
        do {
            let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
                filter.setValue(request.sourceImage, forKey: kCIInputImageKey)
                let output = filter.outputImage ?? request.sourceImage
                request.finish(with: output, context: nil)
            }
            return composition
        } catch {
            Log.error("failed to build video composition: \(error)")
            return nil
        }
    }

    private static func rgbToHsv(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let v = maxV
        let s = maxV == 0 ? 0 : delta / maxV
        var h: Float = 0
        if delta != 0 {
            if maxV == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
            if h < 0 { h += 360 }
        }
        return (h, s, v)
    }
}
