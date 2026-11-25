import Foundation

/// Subset of UnityEngine.TextureFormat.
enum UnityTextureFormat: Int32 {
    case alpha8 = 1, rgb24 = 3, rgba32 = 4, bgra32 = 14
    case dxt1 = 10, dxt5 = 12
    case pvrtcRGB4 = 32, pvrtcRGBA4 = 33
    case etcRGB4 = 34
    case etc2RGB = 45, etc2RGBA1 = 46, etc2RGBA8 = 47
    case astcRGB4x4 = 48, astcRGB6x6 = 50, astcRGBA4x4 = 54, astcRGBA6x6 = 56
}

/// Top mip level only.
struct RawTexture {
    var width: Int
    var height: Int
    var format: UnityTextureFormat
    var data: [UInt8]
}

enum ConversionPlan: Equatable {
    case passthrough           // iOS GPUs read ETC/ETC2/ASTC natively
    case decodeToRGBA32        // desktop-only block formats must be decoded
    case unsupported(String)
}

enum TextureConvertError: LocalizedError {
    case unsupported(String)
    case badData(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s), .badData(let s): return s
        }
    }
}

enum TextureConverter {

    static func plan(for format: UnityTextureFormat) -> ConversionPlan {
        switch format {
        case .etcRGB4, .etc2RGB, .etc2RGBA1, .etc2RGBA8,
             .astcRGB4x4, .astcRGB6x6, .astcRGBA4x4, .astcRGBA6x6:
            return .passthrough
        case .rgba32, .bgra32, .rgb24, .alpha8, .dxt1, .dxt5:
            return .decodeToRGBA32
        case .pvrtcRGB4, .pvrtcRGBA4:
            return .unsupported("PVRTC needs a PVRTexLib-based decoder (not included).")
        }
    }

    /// Returns a texture that Metal on iOS can sample.
    static func convertForIOS(_ tex: RawTexture) throws -> RawTexture {
        switch plan(for: tex.format) {
        case .passthrough:
            return tex

        case .unsupported(let reason):
            throw TextureConvertError.unsupported(reason)

        case .decodeToRGBA32:
            let rgba: [UInt8]
            switch tex.format {
            case .rgba32: rgba = tex.data
            case .bgra32: rgba = swizzleBGRA(tex.data)
            case .rgb24:  rgba = expandRGB(tex.data, pixels: tex.width * tex.height)
            case .alpha8: rgba = expandAlpha(tex.data)
            case .dxt1:   rgba = try decodeBC(tex.data, w: tex.width, h: tex.height, dxt5: false)
            case .dxt5:   rgba = try decodeBC(tex.data, w: tex.width, h: tex.height, dxt5: true)
            default:
                throw TextureConvertError.unsupported("No RGBA32 path for \(tex.format)")
            }
            return RawTexture(width: tex.width, height: tex.height, format: .rgba32, data: rgba)
        }
    }

    // MARK: - Simple layout conversions

    private static func swizzleBGRA(_ s: [UInt8]) -> [UInt8] {
        var o = s
        var i = 0
        while i + 3 < o.count {
            o.swapAt(i, i + 2)
            i += 4
        }
        return o
    }

    private static func expandRGB(_ s: [UInt8], pixels: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: pixels * 4)
        for i in 0..<pixels {
            out[i * 4]     = s[i * 3]
            out[i * 4 + 1] = s[i * 3 + 1]
            out[i * 4 + 2] = s[i * 3 + 2]
        }
        return out
    }

    private static func expandAlpha(_ s: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: s.count * 4)
        for i in 0..<s.count { out[i * 4 + 3] = s[i] }
        return out
    }

    // MARK: - BC1 (DXT1) / BC3 (DXT5) decoder

    typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    static func decodeBC(_ src: [UInt8], w: Int, h: Int, dxt5: Bool) throws -> [UInt8] {
        let bw = (w + 3) / 4, bh = (h + 3) / 4
        let blockSize = dxt5 ? 16 : 8
        guard src.count >= bw * bh * blockSize else {
            throw TextureConvertError.badData(
                "DXT data too short: need \(bw * bh * blockSize), have \(src.count)")
        }

        var out = [UInt8](repeating: 0, count: w * h * 4)
        for by in 0..<bh {
            for bx in 0..<bw {
                let base = (by * bw + bx) * blockSize
                let alpha: [UInt8]? = dxt5 ? alphaBlock(src, base) : nil
                let colors = colorBlock(src, dxt5 ? base + 8 : base, allowTransparent: !dxt5)

                for p in 0..<16 {
                    let x = bx * 4 + p % 4
                    let y = by * 4 + p / 4
                    guard x < w, y < h else { continue }
                    let o = (y * w + x) * 4
                    let c = colors[p]
                    out[o]     = c.r
                    out[o + 1] = c.g
                    out[o + 2] = c.b
                    out[o + 3] = alpha?[p] ?? c.a
                }
            }
        }
        return out
    }

    private static func colorBlock(_ s: [UInt8], _ o: Int, allowTransparent: Bool) -> [RGBA] {
        let c0 = UInt16(s[o]) | (UInt16(s[o + 1]) << 8)
        let c1 = UInt16(s[o + 2]) | (UInt16(s[o + 3]) << 8)
        let p0 = rgb565(c0), p1 = rgb565(c1)

        var pal: [RGBA] = [p0, p1, (0, 0, 0, 255), (0, 0, 0, 255)]
        if c0 > c1 || !allowTransparent {
            pal[2] = mix(p0, p1, 2, 1)
            pal[3] = mix(p0, p1, 1, 2)
        } else {
            pal[2] = mix(p0, p1, 1, 1)
            pal[3] = (0, 0, 0, 0)        // DXT1 1-bit transparency
        }

        let b4 = UInt32(s[o + 4]), b5 = UInt32(s[o + 5])
        let b6 = UInt32(s[o + 6]), b7 = UInt32(s[o + 7])
        let bits: UInt32 = b4 | (b5 << 8) | (b6 << 16) | (b7 << 24)
        return (0..<16).map { (i: Int) -> RGBA in
            let idx = Int((bits >> UInt32(2 * i)) & 3)
            return pal[idx]
        }
    }

    private static func alphaBlock(_ s: [UInt8], _ o: Int) -> [UInt8] {
        let a0 = Int(s[o]), a1 = Int(s[o + 1])
        var pal = [a0, a1]
        if a0 > a1 {
            for i in 1...6 { pal.append(((7 - i) * a0 + i * a1) / 7) }
        } else {
            for i in 1...4 { pal.append(((5 - i) * a0 + i * a1) / 5) }
            pal.append(0)
            pal.append(255)
        }

        var bits: UInt64 = 0
        for k in 0..<6 { bits |= UInt64(s[o + 2 + k]) << UInt64(8 * k) }
        return (0..<16).map { (i: Int) -> UInt8 in
            let idx = Int((bits >> UInt64(3 * i)) & 7)
            return UInt8(pal[idx])
        }
    }

    private static func rgb565(_ c: UInt16) -> RGBA {
        let r = UInt8((c >> 11) & 0x1F)
        let g = UInt8((c >> 5) & 0x3F)
        let b = UInt8(c & 0x1F)
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255)
    }

    private static func mix(_ a: RGBA, _ b: RGBA, _ wa: Int, _ wb: Int) -> RGBA {
        let t = wa + wb
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Int(x) * wa + Int(y) * wb) / t) }
        return (m(a.r, b.r), m(a.g, b.g), m(a.b, b.b), 255)
    }
}
