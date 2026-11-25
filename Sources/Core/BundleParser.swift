import Foundation

// MARK: - Errors

enum UnityBundleError: LocalizedError {
    case badSignature(String)
    case truncated(at: Int)
    case unsupportedCompression(UInt32)
    case decompressionFailed(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .badSignature(let s):        return "Not a UnityFS bundle (signature: \"\(s)\")."
        case .truncated(let o):           return "Bundle is truncated at offset \(o)."
        case .unsupportedCompression(let c): return "Unsupported compression type \(c)."
        case .decompressionFailed(let m): return "Decompression failed: \(m)"
        case .notImplemented(let m):      return m
        }
    }
}

// MARK: - Big-endian reader (UnityFS uses big-endian for header and directory)

struct BinaryReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func need(_ n: Int) throws {
        guard offset + n <= bytes.count else { throw UnityBundleError.truncated(at: offset) }
    }

    mutating func readU8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16BE() throws -> UInt16 {
        try need(2)
        let v = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        offset += 2
        return v
    }

    mutating func readU32BE() throws -> UInt32 {
        try need(4)
        let b0 = UInt32(bytes[offset]), b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2]), b3 = UInt32(bytes[offset + 3])
        offset += 4
        return b0 << 24 | b1 << 16 | b2 << 8 | b3
    }

    mutating func readU64BE() throws -> UInt64 {
        let hi = UInt64(try readU32BE())
        let lo = UInt64(try readU32BE())
        return hi << 32 | lo
    }

    mutating func readI64BE() throws -> Int64 {
        Int64(bitPattern: try readU64BE())
    }

    mutating func readCString() throws -> String {
        var end = offset
        while end < bytes.count && bytes[end] != 0 { end += 1 }
        guard end < bytes.count else { throw UnityBundleError.truncated(at: offset) }
        let s = String(decoding: bytes[offset..<end], as: UTF8.self)
        offset = end + 1
        return s
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        let out = Array(bytes[offset..<(offset + n)])
        offset += n
        return out
    }

    mutating func align(_ n: Int) {
        offset = (offset + n - 1) / n * n
    }
}

// MARK: - Structures

struct StorageBlock {
    let uncompressedSize: UInt32
    let compressedSize: UInt32
    let flags: UInt16          // low 6 bits = compression type
}

struct DirectoryNode {
    let path: String           // e.g. "CAB-xxxx" (serialized file) or "x.resS" (raw resource)
    let offset: Int64          // relative to the decompressed payload
    let size: Int64
    let flags: UInt32          // 4 = serialized file
}

// MARK: - Compression dispatch

enum BundleCompression {
    /// 0 = none, 1 = LZMA, 2 = LZ4, 3 = LZ4HC (same block format as LZ4), 4 = LZHAM
    static func decompress(_ src: ArraySlice<UInt8>, type: UInt32, uncompressedSize: Int) throws -> [UInt8] {
        switch type {
        case 0:
            return Array(src)
        case 2, 3:
            return try LZ4.decodeBlock(src, uncompressedSize: uncompressedSize)
        case 1:
            throw UnityBundleError.notImplemented(
                "LZMA bundles need an LZMA decoder (e.g. LZMA SDK via a C target). Not included yet.")
        default:
            throw UnityBundleError.unsupportedCompression(type)
        }
    }
}

// MARK: - LZ4 block decoder (raw block format, no frame header)

enum LZ4 {
    static func decodeBlock(_ src: ArraySlice<UInt8>, uncompressedSize: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(uncompressedSize)

        var i = src.startIndex
        let end = src.endIndex

        // Reads the extended length bytes used when a nibble equals 15.
        func readLength(_ base: Int) throws -> Int {
            var len = base
            if base == 15 {
                var b: UInt8 = 255
                repeat {
                    guard i < end else { throw UnityBundleError.decompressionFailed("LZ4 length overrun") }
                    b = src[i]
                    i += 1
                    len += Int(b)
                } while b == 255
            }
            return len
        }

        while i < end {
            let token = src[i]
            i += 1

            // 1. Literal run
            let literals = try readLength(Int(token >> 4))
            guard i + literals <= end else {
                throw UnityBundleError.decompressionFailed("LZ4 literal overrun")
            }
            out.append(contentsOf: src[i..<(i + literals)])
            i += literals

            // The final sequence contains only literals.
            if i >= end { break }

            // 2. Match (16-bit little-endian back-reference offset)
            guard i + 2 <= end else { throw UnityBundleError.decompressionFailed("LZ4 offset truncated") }
            let offset = Int(src[i]) | (Int(src[i + 1]) << 8)
            i += 2
            guard offset > 0, offset <= out.count else {
                throw UnityBundleError.decompressionFailed("LZ4 invalid offset \(offset)")
            }
            let matchLen = try readLength(Int(token & 0x0F)) + 4

            // Byte-by-byte copy: matches may overlap their own output.
            let start = out.count - offset
            for k in 0..<matchLen {
                out.append(out[start + k])
            }
        }

        guard out.count == uncompressedSize else {
            throw UnityBundleError.decompressionFailed("expected \(uncompressedSize) bytes, got \(out.count)")
        }
        return out
    }
}

// MARK: - UnityFS container

/// Parses a UnityFS (.unity3d) container: header, block table, directory,
/// and fully decompressed payload. Object-level parsing (SerializedFile) is a later stage.
struct UnityFSBundle {
    let formatVersion: UInt32
    let unityVersion: String
    let unityRevision: String
    let flags: UInt32
    let blocks: [StorageBlock]
    let nodes: [DirectoryNode]
    let payload: [UInt8]

    init(bytes: [UInt8]) throws {
        var r = BinaryReader(bytes)

        let signature = try r.readCString()
        guard signature == "UnityFS" else { throw UnityBundleError.badSignature(signature) }

        let version = try r.readU32BE()
        let uVersion = try r.readCString()
        let uRevision = try r.readCString()
        _ = try r.readI64BE()                              // declared total size (we trust real byte count)
        let compressedInfoSize = Int(try r.readU32BE())
        let uncompressedInfoSize = Int(try r.readU32BE())
        let archiveFlags = try r.readU32BE()

        // Block-info placement. Version >= 7 aligns to 16 bytes.
        // NOTE: alignment rules vary slightly by Unity release; verify with sample bundles.
        let infoAtEnd = (archiveFlags & 0x80) != 0
        let infoStart: Int
        var dataStart: Int
        if infoAtEnd {
            infoStart = bytes.count - compressedInfoSize
            dataStart = r.offset
        } else {
            if version >= 7 { r.align(16) }
            infoStart = r.offset
            dataStart = infoStart + compressedInfoSize
        }
        if version >= 7 { dataStart = (dataStart + 15) & ~15 }

        guard infoStart >= 0, infoStart + compressedInfoSize <= bytes.count else {
            throw UnityBundleError.truncated(at: infoStart)
        }

        // Block table + directory are stored in one compressed stream.
        let infoBytes = try BundleCompression.decompress(
            bytes[infoStart..<(infoStart + compressedInfoSize)],
            type: archiveFlags & 0x3F,
            uncompressedSize: uncompressedInfoSize)

        var ir = BinaryReader(infoBytes)
        _ = try ir.readBytes(16)                           // hash (unused)

        let blockCount = Int(try ir.readU32BE())
        var blockList: [StorageBlock] = []
        for _ in 0..<blockCount {
            let u = try ir.readU32BE()
            let c = try ir.readU32BE()
            let f = try ir.readU16BE()
            blockList.append(StorageBlock(uncompressedSize: u, compressedSize: c, flags: f))
        }

        let nodeCount = Int(try ir.readU32BE())
        var nodeList: [DirectoryNode] = []
        for _ in 0..<nodeCount {
            let off = try ir.readI64BE()
            let size = try ir.readI64BE()
            let nflags = try ir.readU32BE()
            let path = try ir.readCString()
            nodeList.append(DirectoryNode(path: path, offset: off, size: size, flags: nflags))
        }

        // Decompress every data block into one contiguous payload.
        var cursor = dataStart
        var out: [UInt8] = []
        out.reserveCapacity(blockList.reduce(0) { $0 + Int($1.uncompressedSize) })
        for b in blockList {
            let csize = Int(b.compressedSize)
            guard cursor >= 0, cursor + csize <= bytes.count else {
                throw UnityBundleError.truncated(at: cursor)
            }
            let chunk = try BundleCompression.decompress(
                bytes[cursor..<(cursor + csize)],
                type: UInt32(b.flags & 0x3F),
                uncompressedSize: Int(b.uncompressedSize))
            out.append(contentsOf: chunk)
            cursor += csize
        }

        self.formatVersion = version
        self.unityVersion = uVersion
        self.unityRevision = uRevision
        self.flags = archiveFlags
        self.blocks = blockList
        self.nodes = nodeList
        self.payload = out
    }

    /// Bytes of one directory entry (a file inside the bundle).
    func data(for node: DirectoryNode) throws -> ArraySlice<UInt8> {
        let start = Int(node.offset)
        let end = start + Int(node.size)
        guard start >= 0, end <= payload.count else { throw UnityBundleError.truncated(at: start) }
        return payload[start..<end]
    }

    static func open(url: URL) throws -> UnityFSBundle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try UnityFSBundle(bytes: [UInt8](data))
    }
}
