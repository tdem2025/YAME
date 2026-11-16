import YAMECore
import SwiftUI

/// Edit several songs at once: shared fields and one cover for all.
struct BatchEditorView: View {
    @Environment(Library.self) private var library
    let tracks: [TrackItem]

    @ViewState private var artist = ""
    @ViewState private var album = ""
    @ViewState private var albumArtist = ""
    @ViewState private var genre = ""
    @ViewState private var year = ""
    @ViewState private var edited: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(alignment: .top, spacing: 26) {
                    CoverWell(tracks: tracks)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(tracks.count) songs selected")
                            .font(.title3.weight(.semibold))
                        Text("Only the fields you change are applied. Titles and track numbers stay per song.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        field("Artist", \.artist, $artist)
                        field("Album", \.album, $album)
                        field("Album Artist", \.albumArtist, $albumArtist)
                        HStack(spacing: 14) {
                            field("Year", \.year, $year).frame(width: 110)
                            field("Genre", \.genre, $genre)
                        }
                        if let folder = library.folderURL {
                            Button("Use Folder Name “\(folder.lastPathComponent)” as Album") {
                                album = folder.lastPathComponent
                                edited.insert("Album")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                    .glassCard(cornerRadius: 26, padding: 22)
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Songs", systemImage: "music.note.list").font(.headline)
                    ForEach(tracks) { t in
                        HStack(spacing: 10) {
                            CoverThumbnail(image: t.coverImage, size: 28, corner: 6)
                            Text(t.displayTitle).lineLimit(1)
                            Text(t.fields.artist).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if !t.carIssues.filter(\.isProblem).isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help(t.carIssues.filter(\.isProblem).map(\.message).joined(separator: "\n"))
                            }
                            if t.isDirty { Circle().fill(.orange).frame(width: 7, height: 7) }
                        }
                        .font(.callout)
                    }
                }
                .glassCard(cornerRadius: 22, padding: 18)
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Spacer()
                    Button("Apply to \(tracks.count) Songs") { apply() }
                        .buttonStyle(.glass)
                        .disabled(edited.isEmpty)
                    Button {
                        apply()
                        Task { await library.save(tracks) }
                    } label: {
                        Label("Apply & Save", systemImage: "checkmark").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(edited.isEmpty && !tracks.contains(where: \.isDirty))
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .onAppear(perform: loadCommonValues)
    }

    /// A field that shows "Multiple values" when the songs differ.
    private func field(_ label: String, _ key: KeyPath<TagFields, String>, _ binding: Binding<String>) -> some View {
        let values = Set(tracks.map { $0.fields[keyPath: key] })
        let mixed = values.count > 1 && !edited.contains(label)
        return GlassField(
            label: label,
            text: Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; edited.insert(label) }),
            placeholder: mixed ? "Multiple values" : ""
        )
    }

    private func loadCommonValues() {
        func common(_ key: KeyPath<TagFields, String>) -> String {
            let values = Set(tracks.map { $0.fields[keyPath: key] })
            return values.count == 1 ? values.first ?? "" : ""
        }
        artist = common(\.artist)
        album = common(\.album)
        albumArtist = common(\.albumArtist)
        genre = common(\.genre)
        year = common(\.year)
        edited = []
    }

    private func apply() {
        var edit = BatchEdit()
        if edited.contains("Artist") { edit.artist = artist }
        if edited.contains("Album") { edit.album = album }
        if edited.contains("Album Artist") { edit.albumArtist = albumArtist }
        if edited.contains("Genre") { edit.genre = genre }
        if edited.contains("Year") { edit.year = year }
        library.apply(edit, to: tracks)
        edited = []
        library.show("Updated \(tracks.count) songs — remember to save")
    }
}
