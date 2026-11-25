import Foundation

struct ConversionOutput {
    var bundle: [UInt8] = []
    var shaderLog: [String] = []
    var textureLog: [String] = []
    var formats: [String] = []
}

enum ConversionPipeline {
    static let iosPlatformID: UInt32 = 9          // BuildTarget.iOS (Android = 13)

    static func convert(android: UnityFSBundle, iosBase: UnityFSBundle) throws -> ConversionOutput {
        var out = ConversionOutput()

        // --- iOS shader table (Step 2 input) ---
        guard let iosNode = iosBase.nodes.first(where: { $0.flags & 4 != 0 }) else {
            throw UnityBundleError.notImplemented("iOS base bundle has no serialized file.")
        }
        let iosFile = try SerializedFile(bytes: Array(iosBase.data(for: iosNode)))
        let iosShaders: [ShaderRecord] = iosFile.objects
            .filter { $0.classID == SerializedFile.classShader }
            .compactMap { o in shaderName(iosFile, o).map { ShaderRecord(pathID: o.pathID, name: $0) } }
        out.shaderLog.append("iOS base \(iosNode.path): \(iosShaders.count) named shaders")
        let iosExternal = "archive:/\(iosNode.path)/\(iosNode.path)"

        // Raw resource files (.resS) by name, for streamed texture data.
        var resources: [String: ArraySlice<UInt8>] = [:]
        for n in android.nodes where n.flags & 4 == 0 {
            resources[n.path] = try android.data(for: n)
        }

        var entries: [BundleRepacker.Entry] = []
        for node in android.nodes {
            let raw = Array(try android.data(for: node))
            guard node.flags & 4 != 0 else {
                entries.append(.init(name: node.path, data: raw, flags: node.flags))
                continue
            }
            let file = try SerializedFile(bytes: raw)
            var replacements: [Int64: [UInt8]] = [:]

            // --- Step 2: shaders / materials ---
            let androidShaders: [ShaderRecord] = file.objects
                .filter { $0.classID == SerializedFile.classShader }
                .compactMap { o in shaderName(file, o).map { ShaderRecord(pathID: o.pathID, name: $0) } }

            let existing = file.externals.firstIndex(of: iosExternal)
            let iosFileID = Int32((existing ?? file.externals.count) + 1)
            let (table, report) = ShaderMatcher.buildRemap(android: androidShaders, ios: iosShaders,
                                                           iosFileID: iosFileID)
            out.shaderLog.append("\(node.path): \(androidShaders.count) shaders → "
                + "\(report.mapped.count) matched, \(report.fallbackUsed.count) fallback, "
                + "\(report.unmatched.count) unmatched")
            report.unmatched.forEach { out.shaderLog.append("  ✗ no iOS match: \($0)") }
            report.fallbackUsed.forEach { out.shaderLog.append("  ~ \($0)") }

            var remapped = 0
            for o in file.objects where o.classID == SerializedFile.classMaterial {
                guard let f = try? file.fieldRanges(of: o),
                      let fr = f["m_Shader.m_FileID"], let pr = f["m_Shader.m_PathID"] else { continue }
                var d = file.data(of: o)
                let fid = Bin.readInt(d, fr.lowerBound, fr.count, big: file.big)
                let pid = Bin.readInt(d, pr.lowerBound, pr.count, big: file.big)
                guard fid == 0, table[pid] != nil else { continue }
                let np = ShaderMatcher.remap(PPtr(fileID: Int32(fid), pathID: pid), with: table)
                d.replaceSubrange(fr, with: Bin.bytes(Int64(np.fileID), fr.count, big: file.big))
                d.replaceSubrange(pr, with: Bin.bytes(np.pathID, pr.count, big: file.big))
                replacements[o.pathID] = d
                remapped += 1
            }
            out.shaderLog.append("  \(remapped) material(s) re-pointed to iOS shaders")

            // --- Step 3: textures ---
            for o in file.objects where o.classID == SerializedFile.classTexture2D {
                do {
                    let r = try convertTexture(file, o, resources)
                    if let nd = r.data { replacements[o.pathID] = nd }
                    out.textureLog.append(r.message)
                    out.formats.append(r.format)
                } catch {
                    out.textureLog.append("  ✗ texture \(o.pathID): \(error.localizedDescription)")
                }
            }

            let addExt = (remapped > 0 && existing == nil) ? [iosExternal] : []
            let newBytes = file.rebuilt(replacing: replacements, platform: iosPlatformID,
                                        addingExternals: addExt)
            entries.append(.init(name: node.path, data: newBytes, flags: node.flags))
        }

        out.formats = Array(Set(out.formats)).sorted()
        out.bundle = BundleRepacker.pack(entries: entries,
                                         unityVersion: android.unityVersion,
                                         unityRevision: android.unityRevision)
        return out
    }

    // MARK: - Helpers

    static func shaderName(_ f: SerializedFile, _ o: ObjectInfo) -> String? {
        guard let fields = try? f.fieldRanges(of: o) else { return nil }
        let d = f.data(of: o)
        for key in ["m_ParsedForm.m_Name", "m_Name"] {
            if let r = fields[key], let s = Bin.readString(d, r.lowerBound, big: f.big), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Bytes occupied by mip level 0 for formats we decode.
    private static func topMipBytes(_ f: UnityTextureFormat, _ w: Int, _ h: Int) -> Int? {
        let blocks = ((w + 3) / 4) * ((h + 3) / 4)
        switch f {
        case .rgba32, .bgra32: return w * h * 4
        case .rgb24:           return w * h * 3
        case .alpha8:          return w * h
        case .dxt1:            return blocks * 8
        case .dxt5:            return blocks * 16
        default:               return nil
        }
    }

    private static func convertTexture(_ file: SerializedFile, _ o: ObjectInfo,
                                       _ resources: [String: ArraySlice<UInt8>])
        throws -> (data: [UInt8]?, message: String, format: String) {

        let f = try file.fieldRanges(of: o)
        let d = file.data(of: o)
        let be = file.big
        func int(_ key: String) -> Int? {
            f[key].map { Int(Bin.readInt(d, $0.lowerBound, $0.count, big: be)) }
        }
        guard let w = int("m_Width"), let h = int("m_Height"),
              let fmtRaw = int("m_TextureFormat"), let imgR = f["image data"] else {
            throw TextureConvertError.badData("Texture2D is missing expected fields")
        }
        let name = f["m_Name"].flatMap { Bin.readString(d, $0.lowerBound, big: be) } ?? "#\(o.pathID)"
        guard let fmt = UnityTextureFormat(rawValue: Int32(fmtRaw)) else {
            return (nil, "  ? \(name) \(w)x\(h) unknown format \(fmtRaw), left unchanged", "format \(fmtRaw)")
        }
        let label = String(describing: fmt)
        let mips = int("m_MipCount") ?? 1

        if TextureConverter.plan(for: fmt) == .passthrough {
            return (nil, "  ✓ \(name) \(w)x\(h) \(label) mips=\(mips) → passthrough (iOS-native)", label)
        }
        guard let top = topMipBytes(fmt, w, h) else {
            throw TextureConvertError.unsupported("\(name): \(label) cannot be converted")
        }

        // Fetch pixel bytes: inline, or from the .resS stream.
        var pix: [UInt8]
        let inlineLen = Int(Bin.readInt(d, imgR.lowerBound, 4, big: be))
        if inlineLen > 0 {
            pix = Array(d[(imgR.lowerBound + 4)..<(imgR.lowerBound + 4 + inlineLen)])
        } else if let so = f["m_StreamData.offset"], let ss = f["m_StreamData.size"],
                  let sp = f["m_StreamData.path"],
                  let path = Bin.readString(d, sp.lowerBound, big: be) {
            let off = Int(Bin.readInt(d, so.lowerBound, so.count, big: be))
            let size = Int(Bin.readInt(d, ss.lowerBound, ss.count, big: be))
            let key = path.split(separator: "/").last.map(String.init) ?? path
            guard let res = resources[key], off >= 0, size >= 0, off + size <= res.count else {
                throw TextureConvertError.badData("\(name): stream \(key) not found in bundle")
            }
            pix = Array(res[(res.startIndex + off)..<(res.startIndex + off + size)])
        } else {
            throw TextureConvertError.badData("\(name): no image data")
        }
        guard pix.count >= top else { throw TextureConvertError.badData("\(name): pixel data too short") }
        pix = Array(pix.prefix(top))                       // keep mip 0 only

        let conv = try TextureConverter.convertForIOS(
            RawTexture(width: w, height: h, format: fmt, data: pix))

        // Patch the object: fixed-size fields in place, image data replaced, stream cleared.
        var edits: [(Range<Int>, [UInt8])] = []
        func put(_ key: String, _ v: Int) {
            if let r = f[key] { edits.append((r, Bin.bytes(Int64(v), r.count, big: be))) }
        }
        put("m_TextureFormat", Int(conv.format.rawValue))
        put("m_MipCount", 1)
        put("m_CompleteImageSize", conv.data.count)
        var img = Bin.bytes(Int64(conv.data.count), 4, big: be) + conv.data
        while img.count % 4 != 0 { img.append(0) }
        edits.append((imgR, img))
        put("m_StreamData.offset", 0)
        put("m_StreamData.size", 0)
        if let r = f["m_StreamData.path"] { edits.append((r, Bin.bytes(0, 4, big: be))) }

        var nd = d
        for (r, b) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            nd.replaceSubrange(r, with: b)
        }
        return (nd, "  ✓ \(name) \(w)x\(h) \(label) → rgba32 (\(conv.data.count) B, mips \(mips)→1)", label)
    }
}
