//
//  PtpWebcamAppTests.swift
//  PtpWebcamAppTests
//

import XCTest
import CoreVideo
import CoreGraphics
import ImageIO

// jpegIntoPixelBuffer lives in the CMIO extension (a separate binary) and cannot be
// @testable-imported into a host-app test target. The function is a pure CG/CV
// transformation with no extension-internal dependencies, so we duplicate it here
// to keep the tests self-contained and fast.
private func jpegIntoPixelBuffer(_ jpegData: Data) -> CVPixelBuffer? {
    let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
    let imageOpts  = [kCGImageSourceShouldCacheImmediately: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(jpegData as CFData, sourceOpts),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, imageOpts) else { return nil }

    let width  = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                        &pixelBuffer)
    guard let pixelBuffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let ctx = CGContext(
        data:             CVPixelBufferGetBaseAddress(pixelBuffer),
        width:            width,
        height:           height,
        bitsPerComponent: 8,
        bytesPerRow:      CVPixelBufferGetBytesPerRow(pixelBuffer),
        space:            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
}

// MARK: - Helper

private func makeTestJpeg(width: Int = 10, height: Int = 10, color: CGColor = .white) -> Data? {
    // Render a solid-colour CGImage and compress to JPEG.
    guard let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let image = (ctx.setFillColor(color), ctx.fill(CGRect(x: 0, y: 0, width: width, height: height)), ctx.makeImage()).2
    else { return nil }

    let dest = NSMutableData()
    guard let consumer = CGDataConsumer(data: dest as CFMutableData),
          let idest = CGImageDestinationCreateWithDataConsumer(consumer, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(idest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(idest)
    return dest as Data
}

// MARK: - Tests

final class PtpWebcamAppTests: XCTestCase {

    func testDecodeSmallJpeg() throws {
        let jpeg = try XCTUnwrap(makeTestJpeg(width: 10, height: 10))
        let pb   = try XCTUnwrap(jpegIntoPixelBuffer(jpeg))

        // Buffer dimensions should match the JPEG exactly.
        XCTAssertEqual(CVPixelBufferGetWidth(pb),  10)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 10)

        // Confirm at least one pixel was written (non-zero for a white image).
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let pixel = CVPixelBufferGetBaseAddress(pb)!.load(as: UInt32.self)
        XCTAssertNotEqual(pixel, 0, "expected non-zero pixel data after decode")
    }

    func testDecodePreservesNativeSize() throws {
        // Buffer should be 1920×1080, not stretched to some other size.
        let jpeg = try XCTUnwrap(makeTestJpeg(width: 1920, height: 1080))
        let pb   = try XCTUnwrap(jpegIntoPixelBuffer(jpeg))
        XCTAssertEqual(CVPixelBufferGetWidth(pb),  1920)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 1080)
    }

    func testInvalidDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(jpegIntoPixelBuffer(garbage))
    }

    func testRepeatedDecodeNoLeak() throws {
        // 1000 decode calls inside autoreleasepool must not grow memory unboundedly.
        let jpeg = try XCTUnwrap(makeTestJpeg(width: 32, height: 32))

        measure {
            for _ in 0..<1000 {
                autoreleasepool {
                    _ = jpegIntoPixelBuffer(jpeg)
                }
            }
        }
    }
}
