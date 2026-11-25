import Foundation

// MARK: - Endian-aware integer helpers

enum Bin {
    static func readInt(_ b: [UInt8], _ pos: Int, _ len: Int, big: Bool) -> Int64 {
        var v: UInt64 = 0
        for k in 0..<len {
            v = (v << 8) | UInt64(b[pos + (big ? k : len - 1 - k)])
        }
        if len < 8, v & (UInt64(1) << UInt64(len * 8 - 1)) != 0 {
            v |= ~UInt64(0) << UInt64(len * 8)          // sign-extend
        }
        return Int64(bitPattern: v)
    }

    static func bytes(_ value: Int64, _ len: Int, big: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: len)
        let u = UInt64(bitPattern: value)
        for k in 0..<len {
            out[big ? len - 1 - k : k] = UInt8((u >> UInt64(8 * k)) & 0xFF)
        }
        return out
    }

    static func readString(_ d: [UInt8], _ pos: Int, big: Bool) -> String? {
        guard pos >= 0, pos + 4 <= d.count else { return nil }
        let n = Int(readInt(d, pos, 4, big: big))
        guard n >= 0, pos + 4 + n <= d.count else { return nil }
        return String(decoding: d[(pos + 4)..<(pos + 4 + n)], as: UTF8.self)
    }
}

struct EndianReader {
    let bytes: [UInt8]
    var offset: Int
    var big: Bool

    init(_ bytes: [UInt8], offset: Int = 0, big: Bool = true) {
        self.bytes = bytes; self.offset = offset; self.big = big
    }

    mutating func int(_ len: Int) throws -> Int64 {
        guard offset >= 0, offset + len <= bytes.count else { throw UnityBundleError.truncated(at: offset) }
        defer { offset += len }
        return Bin.readInt(bytes, offset, len, big: big)
    }
    mutating func u8() throws -> UInt8 { try UInt8(truncatingIfNeeded: int(1)) }
    mutating func u16() throws -> UInt16 { try UInt16(truncatingIfNeeded: int(2)) }
    mutating func i32() throws -> Int32 { try Int32(truncatingIfNeeded: int(4)) }
    mutating func u32() throws -> UInt32 { try UInt32(truncatingIfNeeded: int(4)) }
    mutating func i64() throws -> Int64 { try int(8) }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, offset + n <= bytes.count else { throw UnityBundleError.truncated(at: offset) }
        offset += n
    }
    mutating func cstring() throws -> String {
        var end = offset
        while end < bytes.count && bytes[end] != 0 { end += 1 }
        guard end < bytes.count else { throw UnityBundleError.truncated(at: offset) }
        defer { offset = end + 1 }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
    mutating func align(_ n: Int) { offset = (offset + n - 1) / n * n }
}

// MARK: - TypeTree model

/// Unity's built-in string table, referenced by offset (high bit set) from TypeTree nodes.
/// Order matters: offsets are computed from it. Verify against UnityPy's CommonString if a
/// type name ever looks wrong.
private let commonStrings: [UInt32: String] = {
    let list = ["AABB", "AnimationClip", "AnimationCurve", "AnimationState", "Array", "Base",
        "BitField", "bitset", "bool", "char", "ColorRGBA", "Component", "data", "deque", "double",
        "dynamic_array", "FastPropertyName", "first", "float", "Font", "GameObject", "Generic Mono",
        "GradientNEW", "GUID", "GUIStyle", "int", "list", "long long", "map", "Matrix4x4f", "MdFour",
        "MonoBehaviour", "MonoScript", "m_ByteSize", "m_Curve", "m_EditorClassIdentifier",
        "m_EditorHideFlags", "m_Enabled", "m_ExtensionPtr", "m_GameObject", "m_Index", "m_IsArray",
        "m_IsStatic", "m_MetaFlag", "m_Name", "m_ObjectHideFlags", "m_PrefabInternal",
        "m_PrefabParentObject", "m_Script", "m_StaticEditorFlags", "m_Type", "m_Version", "Object",
        "pair", "PPtr<Component>", "PPtr<GameObject>", "PPtr<Material>", "PPtr<MonoBehaviour>",
        "PPtr<MonoScript>", "PPtr<Object>", "PPtr<Prefab>", "PPtr<Sprite>", "PPtr<TextAsset>",
        "PPtr<Texture>", "PPtr<Texture2D>", "PPtr<Transform>", "Prefab", "Quaternionf", "Rectf",
        "RectInt", "RectOffset", "second", "set", "short", "size", "SInt16", "SInt32", "SInt64",
        "SInt8", "staticvector", "string", "TextAsset", "TextMesh", "Texture", "Texture2D",
        "Transform", "TypelessData", "UInt16", "UInt32", "UInt64", "UInt8", "unsigned int",
        "unsigned long long", "unsigned short", "vector", "Vector2f", "Vector3f", "Vector4f",
        "m_ScriptingClassIdentifier", "Gradient", "Type*", "int2_storage", "int3_storage",
        "BoundsInt", "m_CorrespondingSourceObject", "m_PrefabInstance", "m_PrefabAsset",
        "FileSize", "Hash128"]
    var map: [UInt32: String] = [:]
    var off: UInt32 = 0
    for s in list { map[off] = s; off += UInt32(s.utf8.count) + 1 }
    return map
}()

struct TypeNode {
    var level: Int
    var isArray: Bool
    var type: String
    var name: String
    var byteSize: Int
    var metaFlag: Int
}

struct SerializedType {
    var classID: Int
    var nodes: [TypeNode]
}

struct ObjectInfo {
    var pathID: Int64
    var byteStart: Int          // relative to dataOffset
    var byteSize: Int
    var classID: Int
    var typeIndex: Int
    var byteStartPos: Int       // absolute position of the byteStart field (for rewriting)
    var byteSizePos: Int
}

// MARK: - TypeTree walker: finds the byte range of every field in an object

struct TypeTreeWalker {
    let nodes: [TypeNode]
    let data: [UInt8]
    let big: Bool
    private var pos = 0
    private var fields: [String: Range<Int>] = [:]

    private init(nodes: [TypeNode], data: [UInt8], big: Bool) {
        self.nodes = nodes; self.data = data; self.big = big
    }

    /// Returns dotted-path → byte range (relative to the object's start).
    /// Fields inside arrays are not recorded.
    static func walk(nodes: [TypeNode], data: [UInt8], big: Bool) throws -> [String: Range<Int>] {
        var w = TypeTreeWalker(nodes: nodes, data: data, big: big)
        guard !nodes.isEmpty else { return [:] }
        for k in w.children(of: 0) { try w.visit(k, path: nodes[k].name) }
        return w.fields
    }

    private func children(of i: Int) -> [Int] {
        var out: [Int] = []
        var j = i + 1
        while j < nodes.count && nodes[j].level > nodes[i].level {
            if nodes[j].level == nodes[i].level + 1 { out.append(j) }
            j += 1
        }
        return out
    }

    private func int32(at p: Int) throws -> Int {
        guard p >= 0, p + 4 <= data.count else { throw UnityBundleError.truncated(at: p) }
        return Int(Bin.readInt(data, p, 4, big: big))
    }

    private mutating func visit(_ i: Int, path: String?) throws {
        let n = nodes[i]
        let start = pos
        let kids = children(of: i)

        if n.type == "TypelessData" {
            let len = try int32(at: pos)
            guard len >= 0 else { throw UnityBundleError.truncated(at: pos) }
            pos += 4 + len
            pos = (pos + 3) & ~3
        } else if n.isArray && kids.count >= 2 {
            let count = try int32(at: pos)
            pos += 4
            guard count >= 0 else { throw UnityBundleError.truncated(at: pos) }
            let e = kids[1]
            if nodes[e].byteSize > 0 && children(of: e).isEmpty {
                pos += count * nodes[e].byteSize               // fast path for fixed-size elements
            } else {
                for _ in 0..<count { try visit(e, path: nil) }
            }
        } else if kids.isEmpty {
            pos += max(n.byteSize, 0)
        } else {
            for k in kids {
                try visit(k, path: path.map { $0 + "." + nodes[k].name })
            }
        }

        if n.metaFlag & 0x4000 != 0 { pos = (pos + 3) & ~3 }   // "align after" flag
        guard pos <= data.count else { throw UnityBundleError.truncated(at: pos) }
        if let p = path { fields[p] = start..<pos }
    }
}

// MARK: - SerializedFile (versions 9–21, i.e. Unity 5.x – 2021, with TypeTree)

struct SerializedFile {
    static let classMaterial = 21, classTexture2D = 28, classShader = 48

    let bytes: [UInt8]
    let version: Int
    let big: Bool
    let unityVersion: String
    let platform: UInt32
    let platformPos: Int
    let dataOffset: Int
    let types: [SerializedType]
    let objects: [ObjectInfo]
    let externals: [String]
    let extCountPos: Int
    let extEnd: Int

    init(bytes: [UInt8]) throws {
        // Header is always big-endian.
        var h = EndianReader(bytes, big: true)
        _ = try h.u32()                       // metadata size
        _ = try h.u32()                       // file size
        let ver = try Int(h.u32())
        let dOff = try Int(h.u32())
        guard ver >= 9 && ver <= 21 else {
            throw UnityBundleError.notImplemented(
                "SerializedFile version \(ver) is unsupported (supported: 9–21 / Unity 5–2021).")
        }
        let endian = try h.u8()
        try h.skip(3)

        // Metadata follows; its endianness comes from the header flag.
        var r = EndianReader(bytes, offset: h.offset, big: endian != 0)
        let uv = try r.cstring()
        let pPos = r.offset
        let plat = try r.u32()
        var hasTree = true
        if ver >= 13 { hasTree = try r.u8() != 0 }
        if hasTree && ver < 12 {
            throw UnityBundleError.notImplemented("Legacy (pre-12) TypeTree layout is not supported.")
        }

        // Types
        let typeCount = try Int(r.i32())
        var typeList: [SerializedType] = []
        for _ in 0..<typeCount {
            let classID = try Int(r.i32())
            if ver >= 16 { _ = try r.u8() }                        // isStrippedType
            if ver >= 17 { try r.skip(2) }                         // scriptTypeIndex
            if ver >= 13 {
                if (ver < 16 && classID < 0) || (ver >= 16 && classID == 114) { try r.skip(16) }
                try r.skip(16)                                     // old type hash
            }
            var nodes: [TypeNode] = []
            if hasTree {
                let nodeCount = try Int(r.i32())
                let strSize = try Int(r.i32())
                struct Raw { var level: Int; var flags: UInt8; var tOff: UInt32; var nOff: UInt32
                             var size: Int; var meta: Int }
                var raws: [Raw] = []
                for _ in 0..<nodeCount {
                    try r.skip(2)                                  // node version
                    let level = Int(try r.u8())
                    let flags = try r.u8()
                    let tOff = try r.u32(), nOff = try r.u32()
                    let size = try Int(r.i32())
                    try r.skip(4)                                  // index
                    let meta = try Int(r.i32())
                    if ver >= 19 { try r.skip(8) }                 // ref type hash
                    raws.append(Raw(level: level, flags: flags, tOff: tOff, nOff: nOff, size: size, meta: meta))
                }
                guard strSize >= 0, r.offset + strSize <= bytes.count else {
                    throw UnityBundleError.truncated(at: r.offset)
                }
                let buf = Array(bytes[r.offset..<(r.offset + strSize)])
                try r.skip(strSize)
                func str(_ off: UInt32) -> String {
                    if off & 0x8000_0000 != 0 { return commonStrings[off & 0x7FFF_FFFF] ?? "?" }
                    let s = Int(off)
                    guard s < buf.count else { return "?" }
                    var e = s
                    while e < buf.count && buf[e] != 0 { e += 1 }
                    return String(decoding: buf[s..<e], as: UTF8.self)
                }
                nodes = raws.map {
                    TypeNode(level: $0.level, isArray: $0.flags & 1 != 0, type: str($0.tOff),
                             name: str($0.nOff), byteSize: $0.size, metaFlag: $0.meta)
                }
                if ver >= 21 {
                    let deps = try Int(r.i32())
                    try r.skip(deps * 4)
                }
            }
            typeList.append(SerializedType(classID: classID, nodes: nodes))
        }

        // Objects
        var bigID = false
        if ver < 14 { bigID = try r.i32() != 0 }
        let objCount = try Int(r.i32())
        var objs: [ObjectInfo] = []
        for _ in 0..<objCount {
            if ver >= 14 { r.align(4) }
            let pid: Int64
            if ver >= 14 || bigID { pid = try r.i64() } else { pid = Int64(try r.i32()) }
            let startPos = r.offset
            let start = try Int(r.u32())
            let sizePos = r.offset
            let size = try Int(r.u32())
            let typeID = try Int(r.i32())
            var classID = typeID
            var typeIdx = typeID
            if ver < 16 {
                classID = Int(try r.u16())
                typeIdx = typeList.firstIndex { $0.classID == classID } ?? -1
            } else {
                classID = typeList.indices.contains(typeID) ? typeList[typeID].classID : -1
            }
            if ver < 17 { try r.skip(2) }          // isDestroyed (<11) / scriptTypeIndex (11–16)
            if ver == 15 { try r.skip(1) }         // stripped flag
            guard dOff + start + size <= bytes.count else { throw UnityBundleError.truncated(at: dOff + start) }
            objs.append(ObjectInfo(pathID: pid, byteStart: start, byteSize: size, classID: classID,
                                   typeIndex: typeIdx, byteStartPos: startPos, byteSizePos: sizePos))
        }

        // Script types
        if ver >= 11 {
            let n = try Int(r.i32())
            for _ in 0..<n {
                try r.skip(4)
                if ver >= 14 { r.align(4); try r.skip(8) } else { try r.skip(4) }
            }
        }

        // Externals (other files this file references)
        let extPos = r.offset
        let extN = try Int(r.i32())
        var ext: [String] = []
        for _ in 0..<extN {
            _ = try r.cstring()                    // always-empty string (v ≥ 6)
            try r.skip(20)                         // GUID (16) + type (4)
            ext.append(try r.cstring())
        }

        self.bytes = bytes; self.version = ver; self.big = endian != 0
        self.unityVersion = uv; self.platform = plat; self.platformPos = pPos
        self.dataOffset = dOff; self.types = typeList; self.objects = objs
        self.externals = ext; self.extCountPos = extPos; self.extEnd = r.offset
    }

    func data(of o: ObjectInfo) -> [UInt8] {
        let s = dataOffset + o.byteStart
        return Array(bytes[s..<(s + o.byteSize)])
    }

    func fieldRanges(of o: ObjectInfo) throws -> [String: Range<Int>] {
        guard types.indices.contains(o.typeIndex), !types[o.typeIndex].nodes.isEmpty else {
            throw UnityBundleError.notImplemented("No TypeTree for class \(o.classID) (bundle built without TypeTrees).")
        }
        return try TypeTreeWalker.walk(nodes: types[o.typeIndex].nodes, data: data(of: o), big: big)
    }

    /// Writes a new file with some objects replaced, an optional new platform ID,
    /// and optional extra externals. The caller must keep PPtr fileIDs consistent
    /// (external N is fileID N+1).
    func rebuilt(replacing: [Int64: [UInt8]], platform newPlatform: UInt32?,
                 addingExternals: [String]) -> [UInt8] {
        var head = Array(bytes[0..<dataOffset])
        var body: [UInt8] = []
        let isBig = big

        func put(_ v: Int, _ pos: Int, bigEndian: Bool) {
            head.replaceSubrange(pos..<(pos + 4), with: Bin.bytes(Int64(v), 4, big: bigEndian))
        }

        for o in objects {
            while body.count % 8 != 0 { body.append(0) }
            let s = dataOffset + o.byteStart
            let obj = replacing[o.pathID] ?? Array(bytes[s..<(s + o.byteSize)])
            put(body.count, o.byteStartPos, bigEndian: isBig)
            put(obj.count, o.byteSizePos, bigEndian: isBig)
            body += obj
        }
        if let p = newPlatform { put(Int(p), platformPos, bigEndian: isBig) }

        var added = 0
        if !addingExternals.isEmpty {
            var blob: [UInt8] = []
            for path in addingExternals {
                blob.append(0)                                           // empty string
                blob += [UInt8](repeating: 0, count: 16)                 // GUID
                blob += Bin.bytes(0, 4, big: isBig)                      // type
                blob += Array(path.utf8) + [0]
            }
            put(externals.count + addingExternals.count, extCountPos, bigEndian: isBig)
            head.insert(contentsOf: blob, at: extEnd)
            added = blob.count
        }
        head += [UInt8](repeating: 0, count: (16 - (dataOffset + added) % 16) % 16)

        // Header fields (always big-endian): metadata size, file size, data offset.
        let oldMeta = Int(Bin.readInt(bytes, 0, 4, big: true))
        put(oldMeta + added, 0, bigEndian: true)
        put(head.count + body.count, 4, bigEndian: true)
        put(head.count, 12, bigEndian: true)
        return head + body
    }
}
