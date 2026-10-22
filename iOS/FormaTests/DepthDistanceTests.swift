import CoreVideo
import XCTest
@testable import Forma

final class DepthDistanceTests: XCTestCase {
    func testDepthUsesMedianAndHonorsThePixelBufferStride() throws {
        let buffer = try makeBuffer(value: 0.22)
        XCTAssertEqual(try XCTUnwrap(DepthDistanceSampler.distance(in: buffer)), 0.22, accuracy: 0.001)
    }

    func testMissingOrInvalidDepthCannotInventADistance() throws {
        for value in [Float.nan, .infinity, 0, 3] {
            XCTAssertNil(DepthDistanceSampler.distance(in: try makeBuffer(value: value)))
        }
    }

    func testMixedNearAndFarSurfacesAreRejected() throws {
        let buffer = try makeBuffer(value: 0.2)
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float.self)
        for y in 0..<48 { for x in 32..<64 { pixels[y * stride + x] = 1.2 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertNil(DepthDistanceSampler.distance(in: buffer))
    }

    private func makeBuffer(value: Float) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_DepthFloat32, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float.self)
        for y in 0..<48 { for x in 0..<64 { pixels[y * stride + x] = value } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
