import YAMECore
import SwiftUI

// MARK: - Number & Rename

struct NumberingSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.namingStyle) private var styleRaw = NamingStyle.artistTitle.rawValue
    @ViewState private var setNumbers = true
    @ViewState private var renameFiles = true
    @ViewState private var working = false

    private var style: NamingStyle { NamingStyle(rawValue: styleRaw) ?? .artistTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Number & Rename").font(.title2.weight(.semibold))
                Text("Uses the order in the sidebar, so your car plays the songs in that order. Drag songs in the list to change it.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Set track numbers (1 of \(library.tracks.count), 2 of \(library.tracks.count)…)", isOn: $setNumbers)
                Toggle("Rename files with a number in front", isOn: $renameFiles)
                Picker("File names", selection: $styleRaw) {
                    ForEach(NamingStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(!renameFiles)
                Text("Many car stereos play a folder in file-name order and ignore track numbers, so doing both is safest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .glassCard(cornerRadius: 20, padding: 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(library.plannedNames(style: style), id: \.0.id) { track, newName in
                        HStack(spacing: 8) {
                            Text(renameFiles ? newName : track.fileName)
                                .lineLimit(1)
                            if renameFiles && newName != track.fileName {
                                Spacer(minLength: 8)
                                Text(track.fileName)
                                    .foregroundStyle(.tertiary)
                                    .strikethrough()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                .padding(14)
            }
            .frame(height: 280)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button("Apply to \(library.tracks.count) Songs") {
                    working = true
                    Task {
                        await library.applyNumbering(setNumbers: setNumbers, renameFiles: renameFiles, style: style)
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(working || (!setNumbers && !renameFiles))
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 640)
    }
}

// MARK: - Clean up

struct CleanupSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @ViewState private var scan = FolderScan()
    @ViewState private var removeAppleDouble = true
    @ViewState private var removeSystem = true
    @ViewState private var chosenOther: Set<URL> = []
    @ViewState private var confirming = false

    private var toDelete: [URL] {
        (removeAppleDouble ? scan.appleDouble : []) + (removeSystem ? scan.system : []) + scan.other.filter { chosenOther.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean Up Folder").font(.title2.weight(.semibold))
                Text("Removes files that aren’t songs, so your car only sees music.")
                    .foregroundStyle(.secondary)
            }

            if scan.junkCount == 0 {
                Label("Nothing to clean — only songs here.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .glassCard(cornerRadius: 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !scan.appleDouble.isEmpty {
                            Toggle(isOn: $removeAppleDouble) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(scan.appleDouble.count) hidden “._” files")
                                    Text("Made by macOS on USB drives. Some cars list them as broken songs.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !scan.system.isEmpty {
                            Toggle(isOn: $removeSystem) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(scan.system.count) system file\(scan.system.count == 1 ? "" : "s")")
                                    Text(scan.system.map(\.lastPathComponent).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        if !scan.other.isEmpty {
                            Divider()
                            Text("Other files").font(.headline)
                            ForEach(scan.other, id: \.self) { url in
                                Toggle(isOn: Binding(
                                    get: { chosenOther.contains(url) },
                                    set: { if $0 { chosenOther.insert(url) } else { chosenOther.remove(url) } }
                                )) {
                                    Label(url.lastPathComponent, systemImage: FolderScanner.isLikelyJunk(url) ? "photo" : "doc")
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(16)
                }
                .frame(maxHeight: 320)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }

            HStack {
                Spacer()
                Button("Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                if scan.junkCount > 0 {
                    Button("Delete \(toDelete.count) File\(toDelete.count == 1 ? "" : "s")", role: .destructive) { confirming = true }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                        .disabled(toDelete.isEmpty)
                }
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 560)
        .onAppear(perform: rescan)
        .confirmationDialog("Remove \(toDelete.count) file(s)?", isPresented: $confirming) {
            Button("Remove", role: .destructive) {
                library.delete(toDelete)
                rescan()
            }
        } message: {
            Text("Hidden “._” and system files are deleted. Anything else goes to the Trash, and ⌘Z puts it back.")
        }
    }

    private func rescan() {
        scan = library.scanFolder() ?? FolderScan()
        chosenOther = Set(scan.other.filter(FolderScanner.isLikelyJunk))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Pref.coverSize) private var coverSize = 500
    @AppStorage(Pref.jpegQuality) private var quality = 0.9
    @AppStorage(Pref.writeID3v1) private var writeV1 = true
    @AppStorage(Pref.removeAppleDouble) private var removeAppleDouble = true
    @AppStorage(Pref.namingStyle) private var namingStyle = NamingStyle.artistTitle.rawValue
    @AppStorage(Pref.autoRenameFiles) private var autoRenameFiles = true

    var body: some View {
        Form {
            Section("Auto-Number") {
                Toggle("Keep track numbers in step with the list", isOn: Binding(
                    get: { Library.shared.autoNumber }, set: { Library.shared.setAutoNumber($0) }))
                Toggle("Also renumber file names that start with a number (“07 …”)", isOn: $autoRenameFiles)
                Text("Adding a song to a 50-song folder makes every song “of 51”. Dragging songs updates their numbers. Only the tag is rewritten, so it’s quick even on USB drives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Covers") {
                Picker("Cover size", selection: $coverSize) {
                    Text("500 × 500 (recommended)").tag(500)
                    Text("600 × 600").tag(600)
                    Text("800 × 800").tag(800)
                }
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: $quality, in: 0.6...1.0, step: 0.05)
                        Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section("Saving") {
                Toggle("Also write an ID3v1 tag (for older stereos)", isOn: $writeV1)
                Toggle("Remove macOS “._” files after saving", isOn: $removeAppleDouble)
                Picker("File names", selection: $namingStyle) {
                    ForEach(NamingStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Text("Tags are always saved as ID3v2.3 with Latin-1 or UTF-16 text, which car head units (including Mercedes-Benz) read best. Audio is never re-encoded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
