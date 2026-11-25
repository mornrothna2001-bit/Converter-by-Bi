import SwiftUI
import UniformTypeIdentifiers

// MARK: - View model: runs the 3-step pipeline and logs progress

@MainActor
final class ConverterModel: ObservableObject {

    enum Slot: String, Identifiable {
        case android, ios
        var id: String { rawValue }
    }

    enum StepState { case pending, running, done, skipped, failed }

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    @Published var androidURL: URL?
    @Published var iosBaseURL: URL?
    @Published var steps: [StepState] = [.pending, .pending, .pending]
    @Published var logs: [LogLine] = []
    @Published var androidSizeText = "—"
    @Published var detectedFormats: [String] = []
    @Published var exportedURL: URL?
    @Published var isBusy = false

    func set(_ slot: Slot, _ url: URL) {
        switch slot {
        case .android: androidURL = url
        case .ios:     iosBaseURL = url
        }
    }

    private func log(_ text: String, error: Bool = false) {
        logs.append(LogLine(text: text, isError: error))
    }

    func runPipeline() async {
        guard let android = androidURL, let base = iosBaseURL else {
            log("Select both bundles first.", error: true)
            return
        }
        isBusy = true
        defer { isBusy = false }
        logs = []
        detectedFormats = []
        exportedURL = nil
        steps = [.running, .pending, .pending]
        androidSizeText = ByteCountFormatter.string(fromByteCount: fileSize(android), countStyle: .file)

        // [1] Container parse
        log("[1] Reading Bundle & Unpacking Android Assets")
        do {
            let androidBundle = try await Task.detached { try UnityFSBundle.open(url: android) }.value
            let iosBundle = try await Task.detached { try UnityFSBundle.open(url: base) }.value
            log("Android: Unity \(androidBundle.unityVersion), \(androidBundle.nodes.count) entries, "
                + "\(androidBundle.payload.count) bytes unpacked")
            for n in androidBundle.nodes { log("  • \(n.path) (\(n.size) B)") }
            log("iOS base: Unity \(iosBundle.unityVersion), \(iosBundle.nodes.count) entries")
            if androidBundle.unityVersion != iosBundle.unityVersion {
                log("Unity version mismatch. Serialized objects may not load. "
                    + "Use an iOS base built with the same Unity version.", error: true)
            }
            steps[0] = .done
        } catch {
            steps[0] = .failed
            log(error.localizedDescription, error: true)
            return
        }

        // [2] Shader matching. Needs the SerializedFile parser, which is not in this build.
        steps[1] = .running
        log("[2] Matching iOS Metal Shaders & ShaderVariants")
        log("Shader object enumeration needs the SerializedFile/TypeTree parser. "
            + "Remap skipped. The matcher is ready (ShaderMatcher.buildRemap).", error: true)
        steps[1] = .skipped

        // [3] Texture conversion. Same limitation as step 2.
        steps[2] = .running
        log("[3] Converting Unity Textures (ETC2 → ASTC/RGBA32)")
        log("Texture2D extraction needs the SerializedFile parser. Codecs are ready: "
            + "ETC/ETC2/ASTC pass through, DXT/RGB24 decode to RGBA32.", error: true)
        steps[2] = .skipped
    }

    /// Writes a repacked bundle to Documents. This is a round-trip test (container read + write),
    /// not a converted asset yet.
    func exportRoundTrip() {
        guard let android = androidURL else { return }
        do {
            let bundle = try UnityFSBundle.open(url: android)
            var entries: [BundleRepacker.Entry] = []
            for node in bundle.nodes {
                entries.append(.init(name: node.path,
                                     data: Array(try bundle.data(for: node)),
                                     flags: node.flags))
            }
            let bytes = BundleRepacker.pack(entries: entries,
                                            unityVersion: bundle.unityVersion,
                                            unityRevision: bundle.unityRevision)
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let out = docs.appendingPathComponent(
                "\(android.deletingPathExtension().lastPathComponent)_roundtrip.unity3d")
            try Data(bytes).write(to: out, options: .atomic)
            exportedURL = out
            log("Exported \(out.lastPathComponent) (\(bytes.count) bytes). "
                + "Find it in Files › On My iPhone › Unity Asset Converter. "
                + "Copy it manually into dragon2017/assets/… in the game sandbox.")
        } catch {
            log("Export failed: \(error.localizedDescription)", error: true)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Document picker (UIKit bridge)

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true copies the file into the sandbox, so no security-scoped access is needed.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Main UI

struct ContentView: View {
    @StateObject private var model = ConverterModel()
    @State private var picking: ConverterModel.Slot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    fileCard(title: "Android bundle (Art / UI)",
                             url: model.androidURL,
                             slot: .android)
                    fileCard(title: "iOS base bundle (reference)",
                             url: model.iosBaseURL,
                             slot: .ios)

                    infoCard

                    StepCard(index: 1, title: "Reading Bundle & Unpacking Android Assets",
                             state: model.steps[0])
                    StepCard(index: 2, title: "Matching iOS Metal Shaders & ShaderVariants",
                             state: model.steps[1])
                    StepCard(index: 3, title: "Converting Unity Textures (ETC2 → ASTC/RGBA32)",
                             state: model.steps[2])

                    logView

                    Button {
                        Task { await model.runPipeline() }
                    } label: {
                        Label("Run Pipeline", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.androidURL == nil || model.iosBaseURL == nil)

                    Button {
                        model.exportRoundTrip()
                    } label: {
                        Label("Export iOS Bundle", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.androidURL == nil)

                    if let url = model.exportedURL {
                        ShareLink(item: url) {
                            Label("Save to Files", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Unity → iOS")
            .sheet(item: $picking) { slot in
                DocumentPicker { url in model.set(slot, url) }
            }
        }
    }

    private func fileCard(title: String, url: URL?, slot: ConverterModel.Slot) -> some View {
        Button { picking = slot } label: {
            HStack {
                Image(systemName: url == nil ? "doc.badge.plus" : "doc.fill")
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(url?.lastPathComponent ?? "Tap to choose a .unity3d file")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
        }
        .buttonStyle(.plain)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Android file size: \(model.androidSizeText)", systemImage: "internaldrive")
            Label(model.detectedFormats.isEmpty
                  ? "Texture formats: none detected yet (needs SerializedFile parser)"
                  : "Texture formats: " + model.detectedFormats.joined(separator: ", "),
                  systemImage: "photo.stack")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.logs) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.isError ? Color.orange : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.06)))
    }
}

struct StepCard: View {
    let index: Int
    let title: String
    let state: ConverterModel.StepState

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading) {
                Text("[\(index)] \(title)").font(.subheadline.bold())
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView()
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:  Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch state {
        case .pending: "Waiting"
        case .running: "Running…"
        case .done:    "Complete"
        case .skipped: "Not yet implemented in this build"
        case .failed:  "Failed. See log."
        }
    }
}
