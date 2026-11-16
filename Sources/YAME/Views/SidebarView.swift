import YAMECore
import SwiftUI

struct SidebarView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library

        List(selection: $library.selection) {
            Section {
                ForEach(Array(library.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, number: index + 1, isPlaying: library.playingID == track.id)
                        .tag(track.id)
                }
                .onMove { library.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                if !library.tracks.isEmpty {
                    HStack {
                        Text("Play order")
                        Spacer()
                        Text(library.autoNumber ? "drag to reorder · numbers update automatically" : "drag to reorder")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: TrackItem.ID.self) { ids in
            let items = library.tracks.filter { ids.contains($0.id) }
            Button("Save") { Task { await library.save(items) } }
                .disabled(!items.contains(where: \.isDirty))
            Button("Revert to Saved") { library.revert(items) }
                .disabled(!items.contains(where: \.isDirty))
            Divider()
            Button("Paste Cover") { library.pasteCover(for: Array(ids)) }
            Button("Cover from YouTube…") { library.beginCoverEdit(source: nil, for: Array(ids), youtube: true) }
            Divider()
            if let first = items.first {
                Button(library.playingID == first.id ? "Stop Preview" : "Play Preview") { library.togglePlayback(first) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            Divider()
            Button("Remove from List") { library.removeFromList(ids) }
            Button("Move to Trash", role: .destructive) { library.trashSongs(ids) }
        }
        .onDeleteCommand { library.removeFromList(library.selection) }
        .safeAreaInset(edge: .bottom) {
            if let folder = library.folderURL {
                HStack(spacing: 8) {
                    Image(systemName: library.canEject ? "externaldrive.fill" : "folder.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1)
                        if let vol = library.volumeName {
                            Text(vol).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(10)
            }
        }
    }
}

struct TrackRow: View {
    let track: TrackItem
    let number: Int
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", number))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            CoverThumbnail(image: track.coverImage)
                .overlay {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45), in: .rect(cornerRadius: 7))
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .lineLimit(1)
                Text(track.fields.artist.isEmpty ? "Unknown artist" : track.fields.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if track.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(track.errorMessage ?? "")
            } else if track.isDirty {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }

            Text(formatDuration(track.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
