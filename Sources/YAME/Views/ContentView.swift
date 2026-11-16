import YAMECore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @ViewState private var isDropTargeted = false

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 460)
        } detail: {
            DetailView()
        }
        .navigationTitle(library.title)
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .sheet(item: $library.sheet) { sheet in
            switch sheet {
            case .cover(let request): CoverSheet(request: request)
            case .numbering: NumberingSheet()
            case .cleanup: CleanupSheet()
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = library.banner {
                BannerView(banner: banner)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(for: .seconds(banner.isError ? 5 : 2.5))
                        withAnimation(.snappy) { library.banner = nil }
                    }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // ⌘Y also redoes (the Edit menu shows the Mac-standard ⇧⌘Z).
            Button("Redo") { library.redo() }
                .keyboardShortcut("y")
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadURLs(providers) { library.open(urls: $0) }
            return true
        }
    }

    private var subtitle: String {
        if library.isLoading { return "Loading…" }
        guard !library.tracks.isEmpty else { return "" }
        var parts = ["\(library.tracks.count) song\(library.tracks.count == 1 ? "" : "s")"]
        let dirty = library.dirtyTracks.count
        if dirty > 0 { parts.append("\(dirty) unsaved") }
        return parts.joined(separator: " · ")
    }
}

/// Reads file URLs out of drag-and-drop providers.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    Task {
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        await completion(urls)
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(Library.self) private var library

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { library.presentOpenPanel() } label: {
                Label("Open", systemImage: "folder.badge.plus")
            }
            .help("Open a music folder or MP3s (⌘O)")
        }

        ToolbarItemGroup(placement: .navigation) {
            Button { library.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!library.canUndo)

            Button { library.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .help("Redo (⇧⌘Z or ⌘Y)")
            .disabled(!library.canRedo)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { library.autoNumber }, set: { library.setAutoNumber($0) })) {
                Label("Auto-Number", systemImage: library.autoNumber ? "number.circle.fill" : "number.circle")
            }
            .toggleStyle(.button)
            .help(library.autoNumber
                  ? "Auto-Number is on: adding, removing or dragging songs updates every song’s “n of total” in its file"
                  : "Turn on to keep track numbers in step with the list automatically")

            Button { library.sheet = .numbering } label: {
                Label("Number & Rename", systemImage: "list.number")
            }
            .help("Set track numbers in list order and rename files")
            .disabled(library.tracks.isEmpty)

            Button { library.sheet = .cleanup } label: {
                Label("Clean Up", systemImage: "sparkles")
            }
            .help("Remove ._ files, pasted images and other junk from the folder")
            .disabled(library.folderURL == nil)

            if library.canEject {
                Button { library.eject() } label: {
                    Label("Eject", systemImage: "eject")
                }
                .help("Safely eject \(library.volumeName ?? "the drive")")
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await library.saveAll() }
            } label: {
                Label("Save All", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.glassProminent)
            .help("Save every edited song (⌥⌘S)")
            .disabled(!library.hasUnsavedChanges || library.isSaving)
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let selected = library.selectedTracks
        ZStack {
            AmbientBackground(image: selected.count == 1 ? selected[0].coverImage : selected.first?.coverImage)

            if library.isLoading {
                ProgressView("Reading tags…")
                    .glassCard()
            } else if library.tracks.isEmpty {
                EmptyStateView()
            } else if selected.count == 1 {
                TrackEditorView(track: selected[0])
                    .id(selected[0].id)
            } else if selected.count > 1 {
                BatchEditorView(tracks: selected)
                    .id(Set(selected.map(\.id)))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Select a song to edit it")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .glassCard(cornerRadius: 28, padding: 32)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating.speed(0.3))
            VStack(spacing: 6) {
                Text("Make your music look right in the car")
                    .font(.title2.weight(.semibold))
                Text("Open a folder from your USB drive, or drop MP3s here.\nEdit titles, artists, albums and covers, set the play order, then eject.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                library.presentOpenPanel()
            } label: {
                Label("Open Folder or MP3s…", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .glassCard(cornerRadius: 32, padding: 36)
        .frame(maxWidth: 560)
        .padding()
    }
}
