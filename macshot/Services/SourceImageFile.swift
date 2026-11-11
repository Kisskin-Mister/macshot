import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image file opened for editing (Finder "Open With", drag to the Dock,
/// `open -a macshot file.png`). Cmd+S writes the edited image back into this
/// file in its original format.
///
/// The write goes into the existing file (same inode) rather than replacing it
/// with a new one: tools that watch the file — e.g. Atlassian Companion, which
/// uploads a new attachment version when its temporary file changes — keep
/// tracking it. Only when the file can't be opened for writing in place do we
/// fall back to an atomic replace.
struct SourceImageFile: Sendable {
    enum Format: Sendable, Equatable {
        case png, jpeg, heic

        nonisolated var typeIdentifier: String {
            switch self {
            case .png: return UTType.png.identifier
            case .jpeg: return UTType.jpeg.identifier
            case .heic: return UTType.heic.identifier
            }
        }

        /// Lossy formats are re-encoded at a high fixed quality, independent of
        /// the screenshot quality preference, so repeated saves degrade little.
        nonisolated var lossyQuality: CGFloat? {
            switch self {
            case .png: return nil
            case .jpeg, .heic: return 0.9
            }
        }
    }

    enum WriteMethod: Sendable, Equatable {
        /// Bytes written into the existing file; inode and attributes kept.
        case inPlace
        /// The file was replaced by a new one (different inode).
        case atomicReplace
    }

    let url: URL
    let format: Format

    /// Detects the format from the file contents (not the extension). Returns
    /// nil for files that can't be written back in their own format.
    nonisolated init?(url: URL) {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let utType = UTType(type) else { return nil }
        if utType.conforms(to: .png) {
            format = .png
        } else if utType.conforms(to: .jpeg) {
            format = .jpeg
        } else if utType.conforms(to: .heic) || utType.conforms(to: .heif) {
            // HEIF containers are written back as HEIC, which ImageIO encodes.
            format = .heic
        } else {
            return nil
        }
        self.url = url
    }

    nonisolated var displayName: String {
        FileManager.default.displayName(atPath: url.path)
    }

    /// Encodes `pixels` in the file's format. Pixel dimensions are kept as-is.
    nonisolated func encode(_ pixels: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.typeIdentifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        var properties: [CFString: Any] = [:]
        if let quality = format.lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        return data as Data
    }

    /// Writes `data` into the file. Blocking: call off the main thread.
    @discardableResult
    nonisolated func write(_ data: Data) throws -> WriteMethod {
        // A read-only file stays read-only: don't sidestep the permission by
        // replacing the file through its (writable) parent folder.
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
        }
        var coordinationError: NSError?
        var result: Result<WriteMethod, Error> = .failure(CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]))
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Self.write(data, to: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated static func write(_ data: Data, to url: URL) throws -> WriteMethod {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            // Can't open the existing file for writing (e.g. it is locked by a
            // file system that doesn't allow in-place writes). Replace it.
            try data.write(to: url, options: .atomic)
            return .atomicReplace
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        // Drop the tail of a previously longer image.
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
        return .inPlace
    }
}
