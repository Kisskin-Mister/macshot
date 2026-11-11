import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class SourceImageFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func makePixels(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func writeImage(_ pixels: CGImage, type: UTType, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    func testFormatComesFromContentsNotExtension() throws {
        let pixels = try makePixels(width: 4, height: 4)
        let png = directory.appendingPathComponent("a.png")
        let jpegNamedPNG = directory.appendingPathComponent("b.png")
        let tiff = directory.appendingPathComponent("c.tiff")
        try writeImage(pixels, type: .png, to: png)
        try writeImage(pixels, type: .jpeg, to: jpegNamedPNG)
        try writeImage(pixels, type: .tiff, to: tiff)

        XCTAssertEqual(SourceImageFile(url: png)?.format, .png)
        XCTAssertEqual(SourceImageFile(url: jpegNamedPNG)?.format, .jpeg)
        XCTAssertNil(SourceImageFile(url: tiff), "formats we can't write back keep the export flow")
        XCTAssertNil(SourceImageFile(url: directory.appendingPathComponent("missing.png")))
    }

    func testSaveRewritesSameFileInItsFormat() throws {
        let url = directory.appendingPathComponent("photo.jpg")
        try writeImage(try makePixels(width: 64, height: 32), type: .jpeg, to: url)
        let file = try XCTUnwrap(SourceImageFile(url: url))
        let inodeBefore = try inode(of: url)

        let data = try file.encode(try makePixels(width: 40, height: 20))
        XCTAssertEqual(try file.write(data), .inPlace)

        XCTAssertEqual(try inode(of: url), inodeBefore, "watchers track the file by inode")
        XCTAssertEqual(try Data(contentsOf: url), data)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
    }

    func testShorterContentTruncatesTheOldTail() throws {
        let url = directory.appendingPathComponent("long.png")
        let old = Data(repeating: 0xAB, count: 10_000)
        try old.write(to: url)
        let new = Data(repeating: 0x01, count: 100)

        XCTAssertEqual(try SourceImageFile.write(new, to: url), .inPlace)
        XCTAssertEqual(try Data(contentsOf: url), new)
    }

    func testReadOnlyFileIsNotReplaced() throws {
        let url = directory.appendingPathComponent("locked.png")
        try writeImage(try makePixels(width: 4, height: 4), type: .png, to: url)
        let original = try Data(contentsOf: url)
        let file = try XCTUnwrap(SourceImageFile(url: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        XCTAssertThrowsError(try file.write(Data([1, 2, 3]))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
