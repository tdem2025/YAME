import YAMECore
import SwiftUI

/// Crop / fit / resize a picture into a car-ready cover, with a live preview.
struct CoverSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.coverSize) private var size = 500
    @AppStorage(Pref.jpegQuality) private var quality = 0.9

    let request: CoverRequest

    @ViewState private var source: CGImage?
    @ViewState private var sourceVersion = 0
    @ViewState private var working: CGImage?
    @ViewState private var fit: CoverFit = .crop
    @ViewState private var offset = 0.0
    @ViewState private var trimBars = true
    @ViewState private var preview: CGImage?
    @ViewState private var previewBytes = 0
    @ViewState private var link = ""
    @ViewState private var isFetching = false
    @ViewState private var fetchError: String?

    private var renderKey: String { "\(fit.rawValue)|\(offset)|\(trimBars)|\(size)|\(quality)|\(sourceVersion)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(request.targets.count == 1 ? "Cover" : "Cover for \(request.targets.count) Songs")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let w = working {
                    Text("Source \(w.width)×\(w.height)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if request.startWithYouTube || source == nil {
                youtubeBar
            }

            HStack(alignment: .top, spacing: 26) {
                previewPane
                controls
                    .frame(width: 290)
            }

            HStack {
                Text("Saved as a \(size)×\(size) baseline JPEG\(previewBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(previewBytes), countStyle: .file) : "") — the format car stereos read reliably.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(request.targets.count == 1 ? "Use Cover" : "Use for \(request.targets.count) Songs") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(preview == nil)
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 740)
        .onAppear { setSource(request.source) }
        .task(id: renderKey) { render() }
    }

    // MARK: Parts

    private var youtubeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.red)
            TextField("Paste a YouTube link…", text: $link)
                .textFieldStyle(.plain)
                .onSubmit { fetch() }
            if isFetching { ProgressView().controlSize(.small) }
            Button("Paste") {
                if let s = NSPasteboard.general.string(forType: .string) { link = s; fetch() }
            }
            .buttonStyle(.glass)
            Button("Get Thumbnail") { fetch() }
                .buttonStyle(.glassProminent)
                .disabled(link.isEmpty || isFetching)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .overlay(alignment: .bottomLeading) {
            if let fetchError {
                Text(fetchError).font(.caption).foregroundStyle(.orange).offset(x: 16, y: 20)
            }
        }
        .padding(.bottom, fetchError == nil ? 0 : 14)
    }

    private var previewPane: some View {
        ZStack {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(.quaternary.opacity(0.5))
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 36, weight: .light))
                    Text("Paste a link, drop or paste an image")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 360, height: 360)
        .clipShape(.rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            Task { @MainActor in if let img = await loadImage(from: providers) { setSource(img) } }
            return true
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shape").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Picker("Shape", selection: $fit) {
                    ForEach(CoverFit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(fitHelp).font(.caption).foregroundStyle(.secondary)
            }

            if fit == .crop, let w = working, !CoverProcessor.isSquare(w) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.width > w.height ? "Horizontal position" : "Vertical position")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Slider(value: $offset, in: -1...1) {
                        Text("Position")
                    } minimumValueLabel: {
                        Image(systemName: w.width > w.height ? "arrow.left" : "arrow.up")
                    } maximumValueLabel: {
                        Image(systemName: w.width > w.height ? "arrow.right" : "arrow.down")
                    }
                    .labelsHidden()
                    Button("Center") { offset = 0 }
                        .controlSize(.small)
                        .buttonStyle(.glass)
                }
            }

            Toggle("Trim black bars (YouTube thumbnails)", isOn: $trimBars)

            VStack(alignment: .leading, spacing: 8) {
                Text("Size").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Picker("Size", selection: $size) {
                    Text("500 px (recommended)").tag(500)
                    Text("600 px").tag(600)
                    Text("800 px").tag(800)
                }
                .labelsHidden()
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Paste Image") { if let img = CoverProcessor.imageFromPasteboard() { setSource(img) } }
                    Button("Choose…") { chooseFile() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .glassCard(cornerRadius: 22, padding: 18)
    }

    private var fitHelp: String {
        switch fit {
        case .crop: return "Fills the square; slide to choose what stays in frame."
        case .blur: return "Keeps the whole picture, with a blurred copy behind it."
        case .white: return "Keeps the whole picture on white."
        case .black: return "Keeps the whole picture on black."
        }
    }

    // MARK: Actions

    private func setSource(_ img: CGImage?) {
        source = img
        sourceVersion += 1
    }

    private func render() {
        working = source.map { trimBars ? CoverProcessor.trimmingDarkBars($0) : $0 }
        guard let w = working, let img = CoverProcessor.render(w, fit: fit, offset: offset, size: size) else {
            preview = nil
            previewBytes = 0
            return
        }
        preview = img
        previewBytes = CoverProcessor.jpegData(img, quality: quality)?.count ?? 0
    }

    private func fetch() {
        let input = link
        guard !input.isEmpty else { return }
        isFetching = true
        fetchError = nil
        Task {
            do {
                let img = try await CoverProcessor.youtubeThumbnail(for: input)
                setSource(img)
                trimBars = true
                offset = 0
            } catch {
                fetchError = error.localizedDescription
            }
            isFetching = false
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let img = CoverProcessor.cgImage(from: data) else { return }
        setSource(img)
    }

    private func apply() {
        guard let preview, let data = CoverProcessor.jpegData(preview, quality: quality) else { return }
        library.setCover(CoverArt(data: data, mimeType: "image/jpeg"), for: request.targets)
        dismiss()
    }
}
