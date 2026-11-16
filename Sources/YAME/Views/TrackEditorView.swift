import YAMECore
import SwiftUI
import UniformTypeIdentifiers

struct TrackEditorView: View {
    @Environment(Library.self) private var library
    @Bindable var track: TrackItem

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(alignment: .top, spacing: 26) {
                    CoverWell(tracks: [track])
                    fieldsCard
                }
                infoCard
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassField(label: "Title", text: $track.fields.title, placeholder: track.url.deletingPathExtension().lastPathComponent)
            GlassField(label: "Artist", text: $track.fields.artist, placeholder: "Who sings or made it")
            GlassField(label: "Album", text: $track.fields.album, placeholder: "Usually the folder or playlist name")
            HStack(alignment: .bottom, spacing: 8) {
                GlassField(label: "Album Artist", text: $track.fields.albumArtist, placeholder: "Who made the album or playlist")
                if let folder = library.folderURL, track.fields.album != folder.lastPathComponent {
                    Button("Use Folder Name as Album") { track.fields.album = folder.lastPathComponent }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.bottom, 4)
                }
            }
            HStack(spacing: 14) {
                GlassField(label: "Track", text: intText($track.fields.trackNumber), placeholder: "#", monospacedDigits: true)
                    .frame(width: 70)
                Text("of")
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                GlassField(label: "Total", text: intText($track.fields.trackTotal), placeholder: "#", monospacedDigits: true)
                    .frame(width: 70)
                GlassField(label: "Year", text: $track.fields.year, placeholder: "YYYY", monospacedDigits: true)
                    .frame(width: 90)
                GlassField(label: "Genre", text: $track.fields.genre, placeholder: "e.g. Rock")
            }
        }
        .glassCard(cornerRadius: 26, padding: 22)
        .frame(maxWidth: .infinity)
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Label(track.fileName, systemImage: "doc")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(track.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 12) {
                    if let d = track.duration { Label(formatDuration(d), systemImage: "clock") }
                    Label(versionLabel, systemImage: "tag")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = track.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 70)

            CarReadinessView(issues: track.carIssues)
        }
        .glassCard(cornerRadius: 22, padding: 18)
    }

    private var versionLabel: String {
        switch track.originalVersion {
        case 0: return "No tags yet"
        case 1: return "ID3v1 only"
        default: return "ID3v2.\(track.originalVersion) → saves as v2.3"
        }
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    library.togglePlayback(track)
                } label: {
                    Label(library.playingID == track.id ? "Stop" : "Preview",
                          systemImage: library.playingID == track.id ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.glass)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)

                Spacer()

                if track.isDirty {
                    Button("Revert") { track.revert() }
                        .buttonStyle(.glass)
                }
                Button {
                    Task { await library.save([track]) }
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!track.isDirty || library.isSaving)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }
}

/// The big cover with drop, paste and adjust actions. Works for one or many songs.
struct CoverWell: View {
    @Environment(Library.self) private var library
    let tracks: [TrackItem]
    var side: CGFloat = 290
    @ViewState private var isTargeted = false

    private var ids: [TrackItem.ID] { tracks.map(\.id) }
    private var image: NSImage? { tracks.first?.coverImage }
    private var allSame: Bool {
        guard let first = tracks.first else { return true }
        return tracks.allSatisfy { $0.fields.cover == first.fields.cover }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if let image, allSame {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    VStack(spacing: 10) {
                        Image(systemName: allSame ? "photo.badge.plus" : "square.stack")
                            .font(.system(size: 40, weight: .light))
                        Text(allSame ? "Drop, paste or choose\na cover" : "Different covers")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(isTargeted ? Color.accentColor : .white.opacity(0.15), lineWidth: isTargeted ? 3 : 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .scaleEffect(isTargeted ? 1.02 : 1)
            .animation(.snappy, value: isTargeted)
            .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
                Task { @MainActor in
                    if let img = await loadImage(from: providers) {
                        library.beginCoverEdit(source: img, for: ids)
                    } else {
                        library.show("That isn’t an image.", error: true)
                    }
                }
                return true
            }
            .onTapGesture(count: 2) {
                if let data = tracks.first?.fields.cover?.data, let img = CoverProcessor.cgImage(from: data) {
                    library.beginCoverEdit(source: img, for: ids)
                } else {
                    library.chooseCoverFile(for: ids)
                }
            }
            .contextMenu { menuItems }
            .help("Drop an image, paste one (⇧⌘V), or double-click")

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { library.pasteCover(for: ids) } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Button { library.chooseCoverFile(for: ids) } label: {
                        Label("Choose…", systemImage: "photo")
                    }
                    Button { library.beginCoverEdit(source: nil, for: ids, youtube: true) } label: {
                        Label("YouTube", systemImage: "play.rectangle")
                    }
                }
                .buttonStyle(.glass)
                .labelStyle(.titleAndIcon)
            }

            if allSame, let cover = tracks.first?.fields.cover {
                HStack(spacing: 6) {
                    if let s = cover.pixelSize { Text("\(s.width)×\(s.height)") }
                    Text("·")
                    Text(cover.mimeType.replacingOccurrences(of: "image/", with: "").uppercased())
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(cover.data.count), countStyle: .file))
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: side)
    }

    @ViewBuilder private var menuItems: some View {
        Button("Paste Cover") { library.pasteCover(for: ids) }
        Button("Choose Image…") { library.chooseCoverFile(for: ids) }
        Button("From YouTube…") { library.beginCoverEdit(source: nil, for: ids, youtube: true) }
        if let data = tracks.first?.fields.cover?.data {
            Divider()
            Button("Adjust Crop & Size…") {
                if let img = CoverProcessor.cgImage(from: data) { library.beginCoverEdit(source: img, for: ids) }
            }
            if tracks.count == 1, let t = tracks.first {
                Button("Export Cover…") { library.exportCover(of: t) }
            }
            Button("Copy Cover") {
                NSPasteboard.general.clearContents()
                if let img = NSImage(data: data) { NSPasteboard.general.writeObjects([img]) }
            }
            Divider()
            Button("Remove Cover", role: .destructive) { library.setCover(nil, for: ids) }
        }
    }
}

/// Loads the first image from drag-and-drop providers (image data or an image file).
func loadImage(from providers: [NSItemProvider]) async -> CGImage? {
    for provider in providers {
        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url, url.isFileURL, let data = try? Data(contentsOf: url), let img = CoverProcessor.cgImage(from: data) {
                return img
            }
            if let url, !url.isFileURL, let result = try? await URLSession.shared.data(from: url),
               let img = CoverProcessor.cgImage(from: result.0) {
                return img
            }
        }
        for type in [UTType.png, .jpeg, .tiff, .heic, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let data: Data? = await withCheckedContinuation { cont in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in cont.resume(returning: data) }
            }
            if let data, let img = CoverProcessor.cgImage(from: data) { return img }
        }
    }
    return nil
}
