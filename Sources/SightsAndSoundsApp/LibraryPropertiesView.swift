import GRDB
import SwiftUI
import SightsAndSoundsKit

/// Get Info, for a library: identity, contents, coverage, configuration
/// — facts and jump-offs, not a second editor (Settings is where things
/// change; the one exception is the library's name, whose explicit
/// rename belongs here). Aggregates load off the main actor: a
/// properties window must never beachball on a big library.
struct LibraryPropertiesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let libraryID: UUID

    /// What the window shows: the library's own answer, wherever the
    /// library is.
    private typealias Snapshot = LibraryProperties

    /// True for a library another Mac holds. Its file, its backups and
    /// its place in that Mac's list of libraries are that Mac's.
    private var isRemote: Bool { app.remoteLibraries.ref(for: libraryID) != nil }

    @State private var snapshot: Snapshot?
    @State private var errorText: String?
    @State private var draftName = ""
    @State private var statusText: String?
    @State private var tab: Tab = .info
    @State private var separators = "-._"
    @State private var newExtension = ""

    enum Tab: String, CaseIterable {
        case info, configuration

        var title: String {
            switch self {
            case .info: "Info"
            case .configuration: "Configuration"
            }
        }
    }

    var body: some View {
        Group {
            if let snapshot {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ThemeSegmentedControl(
                            selection: $tab,
                            options: Tab.allCases.map { ($0, $0.title) },
                            emphasis: .neutral)
                        Spacer()
                        if let statusText {
                            Text(statusText)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(Theme.Accent.amber)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.Border.standard).frame(height: 1)
                    }
                    ScrollView {
                        switch tab {
                        case .info: infoTab(snapshot)
                        case .configuration: configurationTab(snapshot)
                        }
                    }
                }
            } else if let errorText {
                ContentUnavailableView(
                    "Could Not Read Library", systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Theme.Surface.content)
        .navigationTitle(snapshot?.info?.name ?? "Library Properties")
        .task { await load() }
    }

    // MARK: - Info

    @ViewBuilder
    private func infoTab(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Identity") {
                row("Name", value: snapshot.info?.name ?? "—")
                if let info = snapshot.info {
                    row("Library ID", value: info.libraryID.uuidString, mono: true)
                    row("Created", value: info.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let path = snapshot.filePath {
                    row("File", value: path, mono: true, truncatesMiddle: true) {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .unavailableRemotely(isRemote)
                    }
                }
                row(
                    "Database size",
                    value: ByteCountFormatter.string(
                        fromByteCount: snapshot.fileBytes, countStyle: .file), mono: true)
                row("Schema migrations applied", value: "\(snapshot.migrations)", mono: true)
            }

            section("Contents") {
                row("Video items", value: "\(snapshot.videoCount)", mono: true)
                row("Audio items", value: "\(snapshot.audioCount)", mono: true)
                row(
                    "Segments",
                    value: "\(snapshot.songs) songs · \(snapshot.clips) clips · \(snapshot.exportedClips) exported",
                    mono: true)
                row(
                    "Media on disk",
                    value: ByteCountFormatter.string(
                        fromByteCount: snapshot.mediaBytes, countStyle: .file), mono: true)
                ForEach(snapshot.sources) { source in
                    row(
                        source.name,
                        value: "\(source.itemCount) items\(source.enabled ? "" : " · disabled")",
                        mono: true,
                        tint: source.enabled ? Theme.Status.green : Theme.Status.orange)
                }
            }

            // The numbers the background workers chase — "is it done
            // churning." Reported from the same sources the jobs use to
            // decide work, never re-derived differently.
            section("Coverage") {
                coverage("Content hashes", snapshot.hashed, of: snapshot.hashable)
                coverage(
                    "Thumbnails on disk", snapshot.thumbnailsOnDisk, of: snapshot.hashable,
                    note: snapshot.thumbnailFailures > 0
                        ? "\(snapshot.thumbnailFailures) failed" : nil)
                coverage("Audio fingerprints", snapshot.fingerprints, of: snapshot.audioCount)
                coverage("Items with scanned text", snapshot.ocrItems, of: snapshot.videoCount)
                row(
                    "Pending duplicate pairs", value: "\(snapshot.pendingDuplicates)",
                    mono: true, tint: Theme.Status.mauve
                ) {
                    Button("Review") {
                        openWindow(
                            id: "aux",
                            value: AuxWindowRequest(libraryID: libraryID, kind: .review))
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                Text("All of it recomputes from disk. A gap here is work the background jobs have not reached yet, not damage.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("History") {
                row(
                    "Last opened",
                    value: app.libraries.first { $0.id == libraryID }?.lastOpenedAt?
                        .formatted(date: .abbreviated, time: .shortened) ?? "—")
                row(
                    "Last backup",
                    value: snapshot.lastBackup?.formatted(date: .abbreviated, time: .shortened)
                        ?? "never"
                ) {
                    Button("Back up now") { backUp() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                row("Operations logged", value: "\(snapshot.jobsLogged)", mono: true) {
                    Button("Open log") { openWindow(id: "log") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
        .padding(16)
    }

    // MARK: - Configuration

    @ViewBuilder
    private func configurationTab(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Name") {
                HStack(spacing: 8) {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12.5))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 9)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .fill(Theme.Surface.well)
                                .stroke(Theme.Border.standard, lineWidth: 1))
                    // The name is also the one in the list of libraries
                    // on the Mac that holds it, which only that Mac can
                    // change: renamed from here the two would disagree.
                    Button("Rename") { rename() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(
                            isRemote || draftName.trimmingCharacters(in: .whitespaces).isEmpty
                                || draftName == snapshot.info?.name)
                        .help(isRemote ? "A library is renamed on the Mac that holds it" : "")
                }
            }

            section("Separator characters") {
                FlowRow(spacing: 5) {
                    ForEach(Array(separators), id: \.self) { character in
                        HStack(spacing: 4) {
                            Text(String(character))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.Text.secondary)
                            Button {
                                separators.removeAll { $0 == character }
                                saveSeparators()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.ui(8))
                                    .foregroundStyle(Theme.Text.disabled)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove separator \(String(character))")
                            .help("Remove this separator")
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Theme.Surface.iconTile))
                    }
                }
                Text("\"dave-matthews.band_live_2024-06-14\" → \"\(separatorExample)\"")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.Accent.amber)
                Text("A category chooses whether to convert separators; the set is the library's, so a hyphen means the same thing everywhere.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            extensionGroup(
                "Video extensions",
                override: snapshot.info?.videoExtensionsOverride,
                appWide: AppSettingsStore.shared.current.videoExtensions,
                isVideo: true)
            extensionGroup(
                "Audio extensions",
                override: snapshot.info?.audioExtensionsOverride,
                appWide: AppSettingsStore.shared.current.audioExtensions,
                isVideo: false)

            section("Vocabulary") {
                row(
                    "Categories, tags, fields",
                    value: "\(snapshot.categories) · \(snapshot.tags) · \(snapshot.fields)",
                    mono: true
                ) {
                    Button("Edit") {
                        openWindow(
                            id: "aux",
                            value: AuxWindowRequest(libraryID: libraryID, kind: .categories))
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
        .padding(16)
    }

    /// An override REPLACES the app-wide list; it never extends it. The
    /// group carries which state it is in, and one button to change it.
    @ViewBuilder
    private func extensionGroup(
        _ title: String, override: [String]?, appWide: [String], isVideo: Bool
    ) -> some View {
        let effective = override ?? appWide
        section(title) {
            HStack(spacing: 8) {
                ThemeBadge(
                    text: override == nil ? "from Settings" : "this library",
                    fill: override == nil ? Theme.Surface.iconTile : Theme.Surface.iconTileSelected,
                    foreground: override == nil ? Theme.Text.disabled : Theme.Accent.amber)
                Spacer()
                Button(override == nil ? "Override here" : "Use app defaults") {
                    setOverride(
                        video: isVideo ? (override == nil ? appWide : nil) : nil,
                        audio: isVideo ? nil : (override == nil ? appWide : nil),
                        changing: isVideo ? .video : .audio)
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            FlowRow(spacing: 5) {
                ForEach(effective.sorted(), id: \.self) { ext in
                    HStack(spacing: 4) {
                        Text(".\(ext)")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(
                                override == nil ? Theme.Text.disabled : Theme.Text.secondary)
                        if override != nil {
                            Button {
                                removeExtension(ext, isVideo: isVideo)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.ui(8))
                                    .foregroundStyle(Theme.Text.disabled)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove extension \(ext)")
                            .help("Remove this extension")
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Theme.Surface.iconTile))
                    .opacity(override == nil ? 0.6 : 1)
                }
            }
            if override != nil {
                Text("Differs from the app-wide list. Existing items are untouched — this changes what the next scan picks up.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Row furniture
    //
    // Every row is a grid: label, value, and a FIXED action column. An
    // optional trailing button without a reserved column drags every
    // column left on that row alone (tokens, layout rule 1).

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).modifier(Theme.sectionLabel())
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.Surface.raised)
                    .stroke(Theme.Border.standard, lineWidth: 1))
        }
    }

    private func row(
        _ label: String, value: String, mono: Bool = false,
        truncatesMiddle: Bool = false, tint: Color? = nil,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(mono ? Theme.mono(11) : Theme.ui(12))
                .foregroundStyle(tint ?? Theme.Text.primary)
                .lineLimit(1)
                .truncationMode(truncatesMiddle ? .middle : .tail)
                .textSelection(.enabled)
            action()
                .frame(width: 76, alignment: .trailing)
        }
    }

    private func coverage(
        _ label: String, _ done: Int, of total: Int, note: String? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 120)
            Text(note.map { "\(done) of \(total) · \($0)" } ?? "\(done) of \(total)")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .frame(width: 112, alignment: .trailing)
            Color.clear.frame(width: 76)
        }
    }

    private var separatorExample: String {
        TagNameFormatter.format(
            "dave-matthews.band_live_2024-06-14", textFormat: .noFormatting,
            separatorsToSpaces: true, separatorCharacters: separators)
    }

    // MARK: - Writes

    private func saveSeparators() {
        let value = separators
        Task {
            do {
                try await app.service(for: libraryID).setSeparatorCharacters(value)
                statusText = "Separators saved."
            } catch { statusText = "\(error)" }
        }
    }

    private enum ExtensionKind { case video, audio }

    private func setOverride(video: [String]?, audio: [String]?, changing: ExtensionKind) {
        // The other kind's override is kept as the window last read it.
        let info = snapshot?.info
        saveOverrides(
            video: changing == .video ? video : info?.videoExtensionsOverride,
            audio: changing == .audio ? audio : info?.audioExtensionsOverride)
    }

    private func removeExtension(_ ext: String, isVideo: Bool) {
        guard let info = snapshot?.info else { return }
        if isVideo {
            saveOverrides(
                video: (info.videoExtensionsOverride ?? []).filter { $0 != ext },
                audio: info.audioExtensionsOverride)
        } else {
            saveOverrides(
                video: info.videoExtensionsOverride,
                audio: (info.audioExtensionsOverride ?? []).filter { $0 != ext })
        }
    }

    private func saveOverrides(video: [String]?, audio: [String]?) {
        Task {
            do {
                try await app.service(for: libraryID).setExtensionOverrides(video: video, audio: audio)
                await load()
            } catch { statusText = "\(error)" }
        }
    }

    private func load() async {
        do {
            // The counts are made by the library, off the main actor
            // and wherever it is: a properties window must never
            // beachball on a big library.
            let loaded = try await app.service(for: libraryID).libraryProperties()
            snapshot = loaded
            draftName = loaded.info?.name ?? ""
            separators = loaded.info?.separatorCharacters ?? "-._"
        } catch {
            errorText = "\(error)"
        }
    }

    /// The one edit Properties owns: renames are explicit acts, and this
    /// is their home. Updates the identity row and the registry.
    private func rename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isRemote else { return }
        Task {
            do {
                try await app.service(for: libraryID).renameLibrary(to: name)
                // The list of libraries takes the name from the library.
                try app.appDatabase?.register(try app.library(for: libraryID))
                app.refresh()
                statusText = "Renamed to \u{201C}\(name)\u{201D}."
                await load()
            } catch {
                statusText = "Rename failed: \(error)"
            }
        }
    }

    private func backUp() {
        Task {
            do {
                let backup = try await app.service(for: libraryID).backUp()
                statusText = "Backed up to \(backup.lastPathComponent)"
                // On the Mac that made it; from another it is named above.
                if !isRemote { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                await load()
            } catch {
                statusText = "Backup failed: \(error)"
            }
        }
    }
}
