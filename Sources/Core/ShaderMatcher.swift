import Foundation

/// A shader as listed in a bundle's object table.
struct ShaderRecord: Hashable {
    let pathID: Int64
    let name: String
}

/// Unity PPtr: fileID 0 = this file; otherwise an index into the externals table.
struct PPtr: Hashable {
    var fileID: Int32
    var pathID: Int64
}

struct ShaderRemapReport {
    var mapped: [String] = []
    var fallbackUsed: [String] = []
    var unmatched: [String] = []
    var strippedKeywords: [String] = []
}

enum ShaderMatcher {
    /// Keywords that exist only in Android/GLES builds. Removed from materials.
    static let androidOnlyKeywords: Set<String> = ["ETC1_EXTERNAL_ALPHA"]

    /// Used when the iOS base has no shader with the same name.
    static let fallbackNames = ["Sprites/Default", "Unlit/Texture", "Mobile/Diffuse"]

    /// Normalizes shader names so "Hidden/X" and "X" compare equal.
    static func normalize(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["hidden/", "legacy shaders/"] where n.hasPrefix(prefix) {
            n.removeFirst(prefix.count)
        }
        return n
    }

    /// Builds a table from Android shader pathIDs to PPtrs in the iOS output file.
    /// Shaders with no match are left out and will render pink, so they're reported.
    static func buildRemap(android: [ShaderRecord],
                           ios: [ShaderRecord],
                           iosFileID: Int32) -> (table: [Int64: PPtr], report: ShaderRemapReport) {
        var byName: [String: ShaderRecord] = [:]
        for s in ios { byName[normalize(s.name)] = s }

        var table: [Int64: PPtr] = [:]
        var report = ShaderRemapReport()

        for src in android {
            if let hit = byName[normalize(src.name)] {
                table[src.pathID] = PPtr(fileID: iosFileID, pathID: hit.pathID)
                report.mapped.append("\(src.name) → iOS pathID \(hit.pathID)")
            } else if let fb = fallbackNames.compactMap({ byName[normalize($0)] }).first {
                table[src.pathID] = PPtr(fileID: iosFileID, pathID: fb.pathID)
                report.fallbackUsed.append("\(src.name) → \(fb.name)")
            } else {
                report.unmatched.append(src.name)
            }
        }
        return (table, report)
    }

    /// Remaps a PPtr. Call ONLY for shader-typed references (e.g. Material.m_Shader),
    /// because pathIDs are only unique within the type being compared.
    static func remap(_ p: PPtr, with table: [Int64: PPtr]) -> PPtr {
        table[p.pathID] ?? p
    }

    /// Splits a material's keyword list into kept and stripped entries.
    static func filterKeywords(_ keywords: [String], report: inout ShaderRemapReport) -> [String] {
        var kept: [String] = []
        for k in keywords {
            if androidOnlyKeywords.contains(k) {
                report.strippedKeywords.append(k)
            } else {
                kept.append(k)
            }
        }
        return kept
    }
}
