//
//  ZipExtractor.swift
//  rwa client
//
//  Minimal ZIP archive extractor for the game downloads fetched from
//  RWA Creator (see doc/GAME-DOWNLOAD.md). Reads the central directory
//  and inflates entries with the system Compression framework, so no
//  third-party dependency is needed. Supports stored (0) and deflated (8)
//  entries; zip64 archives are rejected.
//

import Foundation
import Compression

enum ZipExtractorError: Error, CustomStringConvertible {
    case notAZipArchive
    case zip64Unsupported
    case corruptArchive(String)
    case unsupportedCompressionMethod(UInt16)
    case unsafeEntryPath(String)

    var description: String {
        switch self {
        case .notAZipArchive: return "not a zip archive"
        case .zip64Unsupported: return "zip64 archives are not supported"
        case .corruptArchive(let what): return "corrupt archive: \(what)"
        case .unsupportedCompressionMethod(let m): return "unsupported compression method \(m)"
        case .unsafeEntryPath(let path): return "entry path escapes destination: \(path)"
        }
    }
}

class ZipExtractor {

    /// Extracts all entries of the archive at `archiveUrl` into `destination`,
    /// overwriting existing files.
    static func extract(_ archiveUrl: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archiveUrl, options: .alwaysMapped)
        let eocd = try findEndOfCentralDirectory(data)

        let entryCount = Int(readUInt16(data, eocd + 10))
        var offset = Int(readUInt32(data, eocd + 16))

        for _ in 0..<entryCount {
            offset = try extractEntry(data, centralDirectoryOffset: offset, to: destination)
        }
    }

    // MARK: - Central directory

    private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
        // EOCD record is 22 bytes + up to 64k of archive comment.
        let minEocdSize = 22
        guard data.count >= minEocdSize else { throw ZipExtractorError.notAZipArchive }

        let lowerBound = max(0, data.count - minEocdSize - 65536)
        var pos = data.count - minEocdSize
        while pos >= lowerBound {
            if readUInt32(data, pos) == 0x06054b50 {
                return pos
            }
            pos -= 1
        }
        throw ZipExtractorError.notAZipArchive
    }

    /// Extracts the entry whose central directory record starts at `offset`.
    /// Returns the offset of the next central directory record.
    private static func extractEntry(_ data: Data, centralDirectoryOffset offset: Int, to destination: URL) throws -> Int {
        guard offset + 46 <= data.count, readUInt32(data, offset) == 0x02014b50 else {
            throw ZipExtractorError.corruptArchive("bad central directory record")
        }

        let method = readUInt16(data, offset + 10)
        let compressedSize = Int(readUInt32(data, offset + 20))
        let uncompressedSize = Int(readUInt32(data, offset + 24))
        let nameLength = Int(readUInt16(data, offset + 28))
        let extraLength = Int(readUInt16(data, offset + 30))
        let commentLength = Int(readUInt16(data, offset + 32))
        let localHeaderOffset = Int(readUInt32(data, offset + 42))
        let nextRecord = offset + 46 + nameLength + extraLength + commentLength

        if readUInt32(data, offset + 20) == 0xffffffff ||
           readUInt32(data, offset + 24) == 0xffffffff ||
           readUInt32(data, offset + 42) == 0xffffffff {
            throw ZipExtractorError.zip64Unsupported
        }
        guard offset + 46 + nameLength <= data.count else {
            throw ZipExtractorError.corruptArchive("entry name out of bounds")
        }

        let name = String(decoding: data.subdata(in: (data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)), as: UTF8.self)
        let entryUrl = try safeDestination(for: name, in: destination)

        if name.hasSuffix("/") {
            FileManager.createDirectory(myDir: entryUrl)
            return nextRecord
        }

        // The central directory's name/extra lengths can differ from the local
        // header's, so re-read them to locate the entry data.
        guard localHeaderOffset + 30 <= data.count, readUInt32(data, localHeaderOffset) == 0x04034b50 else {
            throw ZipExtractorError.corruptArchive("bad local header for \(name)")
        }
        let localNameLength = Int(readUInt16(data, localHeaderOffset + 26))
        let localExtraLength = Int(readUInt16(data, localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
        guard dataStart + compressedSize <= data.count else {
            throw ZipExtractorError.corruptArchive("entry data out of bounds for \(name)")
        }

        let compressed = data.subdata(in: (data.startIndex + dataStart)..<(data.startIndex + dataStart + compressedSize))
        let contents: Data
        switch method {
        case 0: // stored
            contents = compressed
        case 8: // deflate
            contents = try inflate(compressed, uncompressedSize: uncompressedSize, entryName: name)
        default:
            throw ZipExtractorError.unsupportedCompressionMethod(method)
        }

        FileManager.createDirectory(myDir: entryUrl.deletingLastPathComponent())
        try contents.write(to: entryUrl, options: .atomic)
        return nextRecord
    }

    // MARK: - Helpers

    private static func inflate(_ compressed: Data, uncompressedSize: Int, entryName: String) throws -> Data {
        if uncompressedSize == 0 {
            return Data()
        }

        var output = Data(count: uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                // COMPRESSION_ZLIB is raw deflate, which is what zip entries use.
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == uncompressedSize else {
            throw ZipExtractorError.corruptArchive("inflate failed for \(entryName)")
        }
        return output
    }

    /// Resolves an entry name inside `destination`, rejecting absolute paths
    /// and `../` traversal (zip-slip).
    private static func safeDestination(for entryName: String, in destination: URL) throws -> URL {
        let root = destination.standardizedFileURL
        let resolved = root.appendingPathComponent(entryName).standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw ZipExtractorError.unsafeEntryPath(entryName)
        }
        return resolved
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        return UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) })
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        return UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }
}
