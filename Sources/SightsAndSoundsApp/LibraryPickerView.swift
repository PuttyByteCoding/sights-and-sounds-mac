import SwiftUI
import SightsAndSoundsKit
import SightsAndSoundsRemote

/// Choose a library to open — spec `docs/design/01-library-picker.md`.
///
/// A **dialog**, not a window. It appears at launch and from File ▸ Open
/// Library…, and it dismisses the moment a library is chosen. A launcher
/// that stays open becomes a place features accumulate; everything worth
/// reading about a library lives in that library's own window under
/// Properties.
///
/// Two contexts, one dialog. At launch there is nothing behind it, so
/// cancel reads **Quit**. From the menu it appears over your work, cancel
/// means cancel, and the window-placement band appears — because only
/// then is there a window to replace.
struct LibraryPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var selection: UUID?
    @State private var placement: Placement = .newWindow
    @State private var showingNewLibrary = false
    @State private var showingConnect = false
    @State private var movingHost: SavedHost?

    private var remote: RemoteLibrariesModel { model.remoteLibraries }

    /// Where a chosen library opens. Only ever asked in the menu context:
    /// at launch there is no window to replace.
    enum Placement: Hashable { case newWindow, thisWindow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Border.standard)

            if model.libraries.isEmpty && remote.hosts.isEmpty {
                emptyState
            } else {
                libraryList
            }

            Divider().overlay(Theme.Border.standard)

            if showsPlacement {
                placementBand
                Divider().overlay(Theme.Border.standard)
            }

            buttonRow
        }
        .frame(width: 620)
        .frame(maxHeight: 620)
        .background(Theme.Surface.dialog)
        .foregroundStyle(Theme.Text.primary)
        .onAppear {
            selection = defaultSelection
            model.refreshOpenLibraryStatus()
        }
        // Each paired Mac is asked what it has now; what it had last
        // time is listed meanwhile.
        .task { await remote.refresh() }
        .sheet(isPresented: $showingConnect) {
            ConnectToAnotherMacSheet()
                .environment(model)
        }
        .sheet(item: $movingHost) { host in
            RemoteHostAddressSheet(host: host)
                .environment(model)
        }
        .onChange(of: model.libraries) { _, _ in
            // A library added or forgotten while the dialog is up must not
            // leave the primary button naming something that is gone.
            if selection == nil || !model.libraries.contains(where: { $0.id == selection }) {
                selection = defaultSelection
            }
        }
        .sheet(isPresented: $showingNewLibrary) {
            NewLibraryView()
                .environment(model)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fromMenu ? "Open Library" : "Sights and Sounds")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
            Text(fromMenu
                 ? "Pick a library to open. Everything already open stays as it is."
                 : "Pick a library to open. Each one is a separate file with its own vocabulary, sources and media.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.loadError {
                Text(error)
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 13)
    }

    // MARK: - List

    private var libraryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.libraries) { library in
                    LibraryPickerRow(
                        library: library,
                        isSelected: selection == library.id,
                        isOpen: model.openLibraryIDs.contains(library.id),
                        offlineSourceCount: model.offlineSourceCounts[library.id],
                        select: { selection = library.id },
                        open: { open(library) })
                }
                // The claim the cached summary makes, stated where it is
                // read rather than in a tooltip.
                if !model.libraries.isEmpty {
                    Text("Counts are as of each library's last close. Whether a drive is plugged in is only known for a library that is open.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Text.quaternary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
                otherMacs
            }
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minHeight: 120)
    }

    // MARK: - On other Macs

    /// The Macs this one has been paired with, each with the libraries
    /// it offers. Listed as last heard while each is asked again.
    @ViewBuilder
    private var otherMacs: some View {
        if let problem = remote.problem {
            Text(problem)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Status.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        ForEach(remote.hosts) { entry in
            RemoteHostHeader(entry: entry, move: { movingHost = entry.host })
            if entry.libraries.isEmpty {
                Text(RemoteHostHeader.emptyLine(for: entry.state))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.quaternary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            ForEach(entry.libraries) { library in
                RemoteLibraryPickerRow(
                    library: library,
                    isSelected: selection == library.id,
                    isOpen: model.openLibraryIDs.contains(library.id),
                    select: { selection = library.id },
                    open: { open(library.id) })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No Libraries")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
            Text("Create your first library to get started.")
                .font(Theme.ui(Theme.TypeScale.body))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(30)
    }

    // MARK: - Placement

    /// Only meaningful when there is something on screen to replace AND
    /// the pick is not the thing already open.
    private var showsPlacement: Bool {
        fromMenu && model.pickerOriginLibraryID != nil && !selectionIsOpen
    }

    private var placementBand: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 13) {
                Text("Open in")
                    .font(Theme.ui(Theme.TypeScale.body, .semibold))
                ThemeSegmentedControl(
                    selection: $placement,
                    options: [(.newWindow, "A new window"), (.thisWindow, "This window")])
            }
            // The consequence gets its own line and a colour — replacing a
            // window closes something, and that should not read like a
            // footnote.
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(placement == .newWindow ? Theme.Status.green : Theme.Status.orange)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Text(placementNote)
                    .font(Theme.ui(12))
                    .foregroundStyle(placement == .newWindow ? Theme.Text.tertiary : Theme.Status.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.Surface.band)
    }

    private var placementNote: String {
        let origin = originLibraryName ?? "The current library"
        return placement == .newWindow
            ? "\(origin) stays open. Two libraries side by side, each window keeping its own filter and queue."
            : "\(origin) closes and its window is reused. Nothing is lost, but you will have to reopen it."
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button("New Library…") { showingNewLibrary = true }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Create a new library from a template")
            AddExistingLibraryButton()
            DemoLibraryButton()
            SignalSamplesLibraryButton()
            Button("Connect to Another Mac…") { showingConnect = true }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Open a library held by another Mac on this network, with a pairing code from that Mac")

            Spacer(minLength: 8)

            Button(fromMenu ? "Cancel" : "Quit") { cancel() }
                .buttonStyle(SecondaryButtonStyle())
                // Esc dismisses; it never quits. From the menu this is
                // Cancel and Esc is its key. At launch it is Quit, and Esc
                // quitting the whole app is not what anyone reaches for
                // Esc to do — ⌘Q still quits.
                .keyboardShortcut(fromMenu ? .cancelAction : nil)

            Button(primaryLabel) {
                if let selection, selectedName != nil { open(selection) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedName == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var primaryLabel: String {
        guard let selectedName else { return "Open" }
        return selectionIsOpen ? "Bring Forward" : "Open \(selectedName)"
    }

    /// The name of what is selected, on this Mac or another.
    private var selectedName: String? {
        guard let selection else { return nil }
        return selected?.name ?? remote.ref(for: selection)?.library.name
    }

    // MARK: - State

    private var fromMenu: Bool { model.pickerContext == .menu }

    private var selected: LibraryRef? {
        model.libraries.first { $0.id == selection }
    }

    private var selectionIsOpen: Bool {
        guard let selection else { return false }
        return model.openLibraryIDs.contains(selection)
    }

    private var originLibraryName: String? {
        guard let id = model.pickerOriginLibraryID else { return nil }
        return model.libraries.first { $0.id == id }?.name
    }

    /// Land on something you can actually open — never on the library
    /// already sitting behind the dialog. Most recently opened first,
    /// because that is the one being come back to.
    private var defaultSelection: UUID? {
        let closed = model.libraries.filter { !model.openLibraryIDs.contains($0.id) }
        let byRecency = closed.sorted {
            ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
        }
        return byRecency.first?.id ?? model.libraries.first?.id
    }

    // MARK: - Actions

    private func open(_ library: LibraryRef) { open(library.id) }

    /// Open a library by the id its window goes by: its own, for one on
    /// this Mac; this Mac's id for it, for one on another.
    private func open(_ libraryID: UUID) {
        if model.openLibraryIDs.contains(libraryID) {
            // Already open: bring it forward rather than loading it twice.
            openWindow(id: "library", value: libraryID)
            dismiss()
            return
        }
        if fromMenu, placement == .thisWindow, let origin = model.pickerOriginLibraryID {
            dismissWindow(id: "library", value: origin)
        }
        openWindow(id: "library", value: libraryID)
        dismiss()
    }

    private func cancel() {
        if fromMenu {
            dismiss()
        } else {
            // Nothing was opened, and the app closes — which is what the
            // button says.
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Other Macs

/// One paired Mac: its name, where it is, and how asking it went.
private struct RemoteHostHeader: View {
    @Environment(AppModel.self) private var model
    let entry: RemoteLibrariesModel.HostEntry
    let move: () -> Void
    @State private var confirmForget = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Text.quaternary)
            Text("ON \(entry.host.name.uppercased())")
                .font(Theme.ui(10.5, .semibold))
                .foregroundStyle(Theme.Text.tertiary)
                .lineLimit(1)
            Text("\(entry.host.address):\(String(entry.host.port))")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.stateLine(for: entry.state))
                .font(Theme.ui(10.5))
                .foregroundStyle(Self.isTrouble(entry.state) ? Theme.Status.warnText : Theme.Text.quaternary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Ask Again") { Task { await model.remoteLibraries.refresh() } }
            Button("Change Address…", action: move)
            Divider()
            Button("Forget This Mac…") { confirmForget = true }
        }
        .confirmationDialog(
            "Forget this Mac?",
            isPresented: $confirmForget
        ) {
            Button("Forget") { model.remoteLibraries.forget(entry.host.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(entry.host.name)\n\nThis Mac will no longer be able to open its libraries; to open them again, pair again with a new code. It still lists this Mac as approved until it is revoked there.")
        }
    }

    static func stateLine(for state: RemoteLibrariesModel.HostEntry.State) -> String {
        switch state {
        case .asking: "Asking\u{2026}"
        case .reachable: "Connected"
        case .unreachable: "Not answering"
        case .refused(let why): why
        }
    }

    static func isTrouble(_ state: RemoteLibrariesModel.HostEntry.State) -> Bool {
        switch state {
        case .asking, .reachable: false
        case .unreachable, .refused: true
        }
    }

    static func emptyLine(for state: RemoteLibrariesModel.HostEntry.State) -> String {
        switch state {
        case .asking: "Asking which libraries it has\u{2026}"
        case .reachable: "It has no libraries."
        case .unreachable: "It is not answering, and has not said before which libraries it has. Is it on, with Remote Access on, at this address?"
        case .refused: "It will not say which libraries it has."
        }
    }
}

/// A library on another Mac. It has no path here and no cached counts:
/// what is known is its name and whose it is.
private struct RemoteLibraryPickerRow: View {
    let library: RemoteLibraryRef
    let isSelected: Bool
    let isOpen: Bool
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.Surface.iconTileSelected : Theme.Surface.iconTile)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "network")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Theme.Accent.amber : Theme.Text.quaternary))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(library.library.name)
                        .font(Theme.ui(13.5, .semibold))
                        .foregroundStyle(isSelected ? Theme.Text.primary : Theme.Text.secondary)
                        .lineLimit(1)
                    if isOpen {
                        ThemeBadge(text: "OPEN")
                    }
                }
                Text("Held by \(library.host.name). Browsed, played and tagged from here; its files stay there.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(isSelected ? Theme.Text.tertiary : Theme.Text.quaternary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.Surface.selectedRow : .clear))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onClicks(single: select, double: open)
    }
}

// MARK: - Row

/// 34pt icon · name + badges · cached summary (mono) · path (mono) ·
/// last-opened right-aligned. Double-click opens.
private struct LibraryPickerRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let library: LibraryRef
    let isSelected: Bool
    let isOpen: Bool
    /// Only ever non-nil for an open library: a shut library cannot be
    /// asked whether its drives are plugged in.
    let offlineSourceCount: Int?
    let select: () -> Void
    let open: () -> Void

    @State private var statusText: String?
    @State private var confirmRestore: URL?
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(library.name)
                        .font(Theme.ui(13.5, .semibold))
                        .foregroundStyle(isSelected ? Theme.Text.primary : Theme.Text.secondary)
                        .lineLimit(1)
                    if isOpen {
                        ThemeBadge(text: "OPEN")
                    }
                    if let offlineSourceCount, offlineSourceCount > 0 {
                        ThemeBadge(
                            text: "\(offlineSourceCount) SOURCE\(offlineSourceCount == 1 ? "" : "S") OFFLINE",
                            fill: Theme.Status.warnBadgeFill,
                            foreground: Theme.Status.orange)
                    }
                }
                Text(summaryLine)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(isSelected ? Theme.Text.tertiary : Theme.Text.quaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                PathText(
                    path: library.filePath,
                    color: isSelected ? Theme.Text.tertiary : Theme.Text.quaternary)
                    .padding(.top, 3)
                if let statusText {
                    Text(statusText)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(2)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(lastOpenedText)
                .font(Theme.ui(11))
                .foregroundStyle(isSelected ? Theme.Text.tertiary : Theme.Text.disabled)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.Surface.selectedRow : .clear))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onClicks(single: select, double: open)
        .contextMenu { contextMenu }
        .confirmationDialog(
            "Remove “\(library.name)” from this list? The library file on disk is NOT deleted — Add Existing… brings it back, never as a duplicate. Close this library's windows before removing.",
            isPresented: $confirmRemove
        ) {
            // Neutral, not destructive: the registry stores where a file
            // is, not the library. Removing is forgetting.
            Button("Remove from List") { model.removeLibrary(id: library.id) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Replace “\(library.name)” with this backup? The current file is archived first (never deleted). Close this library's windows before restoring.",
            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })
        ) {
            Button("Restore", role: .destructive) {
                guard let url = confirmRestore else { return }
                statusText = "Restoring from \(url.lastPathComponent)…"
                Task {
                    do {
                        try await model.restoreLibrary(id: library.id, from: url)
                        statusText = "Restored from \(url.lastPathComponent)"
                    } catch {
                        statusText = "Restore failed: \(error)"
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        }
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Theme.Surface.iconTileSelected : Theme.Surface.iconTile)
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: "books.vertical")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.Accent.amber : Theme.Text.quaternary))
    }

    // MARK: Copy

    /// The cached counts. A library added but never closed since the
    /// cache arrived has none — say so rather than showing five zeroes,
    /// which would read as an empty library.
    private var summaryLine: String {
        guard let summary = library.summary else {
            return "Counts arrive the first time this library is closed"
        }
        let items = Self.number.string(from: NSNumber(value: summary.itemCount)) ?? "\(summary.itemCount)"
        let size = ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        let sources = "\(summary.sourceCount) \(summary.sourceCount == 1 ? "source" : "sources")"
        let categories = "\(summary.categoryCount) \(summary.categoryCount == 1 ? "category" : "categories")"
        let tags = "\(summary.tagCount) \(summary.tagCount == 1 ? "tag" : "tags")"
        return "\(items) items  ·  \(size)  ·  \(sources)  ·  \(categories)  ·  \(tags)"
    }

    /// An open library says so instead of naming a date — "open now" is
    /// the more useful fact, and the date would be this session anyway.
    private var lastOpenedText: String {
        if isOpen { return "open now" }
        guard let date = library.lastOpenedAt else { return "never opened" }
        return Self.lastOpened.string(from: date)
    }

    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let lastOpened: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    // MARK: Context menu

    /// Right, and unchanged from the existing view. Do not introduce a
    /// second label for Properties.
    @ViewBuilder private var contextMenu: some View {
        Button("Properties…", systemImage: "info.circle") { openProperties() }
        Divider()
        Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { backUp() }
        Button("Restore from Backup…", systemImage: "clock.arrow.circlepath") { pickBackup() }
        Divider()
        Button("Remove from List…", systemImage: "minus.circle") { confirmRemove = true }
    }

    private func openProperties() {
        openWindow(id: "properties", value: library.id)
    }

    /// The copy runs off the main actor: a full backup of a large
    /// library used to beachball the picker.
    private func backUp() {
        statusText = "Backing up…"
        Task {
            do {
                let open = try model.library(for: library.id)
                let url = try await open.backUp(into: LibraryDatabase.defaultBackupDirectory())
                statusText = "Backed up to \(url.path)"
            } catch {
                statusText = "Backup failed: \(error)"
            }
        }
    }

    private func pickBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a backup to restore"
        panel.directoryURL = LibraryDatabase.defaultBackupDirectory()
            .appendingPathComponent(library.name, isDirectory: true)
        panel.allowedContentTypes = [.init(filenameExtension: "sqlite")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmRestore = url
    }
}
