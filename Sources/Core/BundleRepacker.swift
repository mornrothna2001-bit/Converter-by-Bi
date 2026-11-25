import Foundation

/// Writes a UnityFS bundle, format version 6, uncompressed.
/// Layout: header | block+directory info | data.
/// Output is larger than LZ4 but is simple and reliable. An LZ4 encoder can be added later.
enum BundleRepacker {

    struct Entry {
        let name: String      // e.g. "CAB-xxxx" or "Texture2D.resS"
        let data: [UInt8]
        let flags: UInt32     // 4 = serialized file, 0 = raw resource
    }

    private struct ByteWriter {
        var bytes: [UInt8] = []

        mutating func u32BE(_ v: UInt32) {
            for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> s) & 0xFF)) }
        }
        mutating func u64BE(_ v: UInt64) {
            for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> s) & 0xFF)) }
        }
        mutating func cstring(_ s: String) {
            bytes += Array(s.utf8)
            bytes.append(0)
        }
        mutating func raw(_ b: [UInt8]) { bytes += b }
    }

    static func pack(entries: [Entry], unityVersion: String, unityRevision: String) -> [UInt8] {
        // 1. Concatenate file data and build the directory.
        var payload: [UInt8] = []
        var directory = ByteWriter()
        directory.u32BE(UInt32(entries.count))
        for e in entries {
            directory.u64BE(UInt64(payload.count))
            directory.u64BE(UInt64(e.data.count))
            directory.u32BE(e.flags)
            directory.cstring(e.name)
            payload += e.data
        }

        // 2. Block info: 16-byte hash, one uncompressed block, then directory.
        var info = ByteWriter()
        info.raw([UInt8](repeating: 0, count: 16))
        info.u32BE(1)
        info.u32BE(UInt32(payload.count))          // uncompressed size
        info.u32BE(UInt32(payload.count))          // compressed size (same)
        info.raw([0, 0])                           // block flags: compression 0
        info.raw(directory.bytes)

        // 3. Header. Written twice: first to measure, then with the real total size.
        func header(total: UInt64, infoSize: UInt32) -> [UInt8] {
            var h = ByteWriter()
            h.cstring("UnityFS")
            h.u32BE(6)
            h.cstring(unityVersion)
            h.cstring(unityRevision)
            h.u64BE(total)
            h.u32BE(infoSize)          // compressed blocks-info size
            h.u32BE(infoSize)          // uncompressed blocks-info size
            h.u32BE(0)                 // flags: no compression, info right after header
            return h.bytes
        }

        let infoSize = UInt32(info.bytes.count)
        let headerLen = header(total: 0, infoSize: infoSize).count
        let total = UInt64(headerLen + info.bytes.count + payload.count)

        return header(total: total, infoSize: infoSize) + info.bytes + payload
    }
}
