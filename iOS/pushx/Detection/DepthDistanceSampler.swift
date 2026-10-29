import CoreGraphics
import CoreVideo
import Foundation

enum DepthDistanceSampler {
    static func distance(in buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        guard width >= 8, height >= 8 else { return nil }
        let pixels = base.assumingMemoryBound(to: Float.self)
        var values: [Double] = []
        for y in 0..<7 {
            for x in 0..<7 {
                let column = width * (35 + x * 5) / 100
                let row = height * (35 + y * 5) / 100
                let value = Double(pixels[row * stride + column])
                if value.isFinite && (0.08...1.5).contains(value) { values.append(value) }
            }
        }
        guard values.count >= 30 else { return nil }
        values.sort()
        let median = values[values.count / 2]
        guard values[values.count * 3 / 4] - values[values.count / 4] <= median * 0.25 else { return nil }
        return median
    }
}
