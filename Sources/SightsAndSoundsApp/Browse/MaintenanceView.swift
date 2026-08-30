import SwiftUI
import SightsAndSoundsKit

/// The three things that touch **files** rather than the database.
///
/// They were three unrelated affordances — a validation sheet, a backup
/// button in Settings, a write-back command in the grid's context menu —
/// and they share one shape: scope, a preview of what would change, the
/// cost, the guarantee, and a way back.
struct MaintenanceView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app

    enum Tab: String, CaseIterable {
        case writeback, backup, validation

        var title: String {
            switch self {
            case .writeback: "Write-back"
            case .backup: "Backup"
            case .validation: "Validation"
            }
        }
    }

    @State private var tab: Tab = .writeback
    @State private var preview: WritebackPreview?
    @State private var previewing = false
    @State private var wholeLibrary = false
    @State private var runs: [TagWriteRun] = []
    @State private var backups: [LibraryDatabase.BackupFile] = []
    @State private var findings: [ValidationFinding] = []
    @State private var stagedCount = 0
    @State private var reclaimable: Int64 = 0
    @State private var sweeping = false
    @State private var status: String?
    @State private var errorText: String?
    @State private var confirmPurge = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                centre
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                sidebar
            }
            footer
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.Surface.content)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                ThemeSegmentedControl(
                    selection: $tab,
                    options: Tab.allCases.map { ($0, $0.title) },
                    emphasis: .neutral)
                Text(headline)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.Text.quaternary)
                Spacer()
                if let status {
                    Text(status)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Accent.amber)
                }
                if let errorText {
                    Text(errorText)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Status.red)
                        .lineLimit(2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(blurb)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tab == .writeback {
                ThemeSegmentedControl(
                    selection: $wholeLibrary,
                    options: [
                        (false, "The \(model.visibleItems.count) filtered items"),
                        (true, "The whole library"),
                    ],
                    emphasis: .neutral)
            }
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var title: String {
        switch tab {
        case .writeback: "Write tags into the files"
        case .backup: "Back up the library"
        case .validation: "Validate the library"
        }
    }

    private var blurb: String {
        switch tab {
        case .writeback:
            "Copy what the library knows into the media files themselves, so another player — or you, in ten years, without this app — can still read it."
        case .backup:
            "A library is one file, so a backup is a copy of it. This does not touch your media — only the database holding tags, fields and history."
        case .validation:
            "Compare what the database believes against what is actually on disk. Findings are reported, never fixed silently."
        }
    }

    private var headline: String {
        switch tab {
        case .writeback:
            guard let preview else { return "no preview yet" }
            return "\(preview.writableFiles.count) items · \(preview.fieldCount) tags · \(preview.replacedCount) existing values replaced"
        case .backup:
            return "\(backups.count) backups"
        case .validation:
            return "\(findings.count) findings · a sweep only observes, it never repairs"
        }
    }

    // MARK: - Centre

    @ViewBuilder private var centre: some View {
        switch tab {
        case .writeback: writebackCentre
        case .backup: backupCentre
        case .validation: validationCentre
        }
    }

    private var writebackCentre: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                mappingBlock
                if previewing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading what the files say now…")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                } else if let preview {
                    ForEach(preview.files) { file in
                        writebackRow(file)
                    }
                } else {
                    Text("Preview reads each file's current tags, so you can see what a write would replace before it replaces it.")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
    }

    /// Which categories write, and to which field — the plan's premise,
    /// shown where the writing happens. Editing it is Categories &
    /// Fields' job.
    private var mappingBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What gets written").modifier(Theme.sectionLabel())
            ForEach(model.vocabulary) { entry in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.categoryHue(entry.category.colorIndex))
                        .frame(width: 6, height: 6)
                    Text(entry.category.name)
                        .font(Theme.ui(12))
                        .foregroundStyle(
                            entry.category.writebackEnabled
                                ? Theme.Text.secondary : Theme.Text.disabled)
                    Text("→")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                    Text(entry.category.writebackEnabled
                        ? StandardFields.effectiveVorbisName(
                            categoryName: entry.category.name,
                            writebackField: entry.category.writebackField)
                        : "not written")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(
                            entry.category.writebackEnabled
                                ? Theme.Accent.amber : Theme.Text.disabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func writebackRow(_ file: WritebackPreview.File) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(file.skipReason == nil
                        ? (file.replacedCount > 0 ? Theme.Accent.amber : Theme.Status.green)
                        : Theme.Text.disabled)
                    .frame(width: 6, height: 6)
                Text(file.fileName)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let reason = file.skipReason {
                    // Skipped is a first-class outcome, listed by name.
                    Text("skipped · \(reason)")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
            }
            ForEach(Array(file.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top, spacing: 8) {
                    Text(field.name)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.disabled)
                        .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.newValues.joined(separator: "; "))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(
                                field.replacesSomething
                                    ? Theme.Accent.amber : Theme.Status.greenBright)
                        if !field.previousValues.isEmpty {
                            // The value being overwritten is load-bearing
                            // data, so it is quaternary or lighter — one
                            // of the three places a sub-AA grey shipped.
                            Text(field.previousValues.joined(separator: "; "))
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.Text.quaternary)
                                .strikethrough()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(file.replacedCount > 0 ? Theme.Surface.selectedRow : Theme.Surface.raised))
    }

    private var backupCentre: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if backups.isEmpty {
                    Text("No backups yet. Back up now writes one dated file into the backup folder.")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.Text.disabled)
                }
                ForEach(backups) { backup in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.timemachine")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.Text.disabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.url.lastPathComponent)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.Text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.Text.disabled)
                                if let name = backup.libraryName {
                                    Text(name)
                                        .font(Theme.ui(10.5))
                                        .foregroundStyle(Theme.Text.quaternary)
                                }
                            }
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.Text.quaternary)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.raised))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
    }

    private var validationCentre: some View {
        Group {
            if findings.isEmpty {
                VStack(spacing: 6) {
                    Text("No Findings")
                        .font(Theme.ui(15, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("Run a sweep to compare the library against the disk.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        // Per FINDING, never rolled up by kind — the path
                        // is the information.
                        ForEach(findings) { finding in
                            findingRow(finding)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func findingRow(_ finding: ValidationFinding) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: finding.kind))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                PathText(path: finding.path, size: 11, color: Theme.Text.primary)
                Text(finding.detail)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer(minLength: 0)
            actionButton(for: finding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func color(for kind: ValidationFindingKind) -> Color {
        switch kind {
        case .missingFile: Theme.Status.red
        case .orphanFile: Theme.Status.blue
        case .sizeMismatch: Theme.Status.orange
        }
    }

    /// One action per kind, and each one is the honest one: a missing
    /// file flags without moving, because there is nothing to move.
    @ViewBuilder private func actionButton(for finding: ValidationFinding) -> some View {
        switch finding.kind {
        case .missingFile:
            if let itemID = finding.mediaItemID {
                Button("Mark for Deletion") {
                    try? model.library.stage(.toDelete, itemID: itemID)
                    reload()
                    model.refreshAll()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        case .orphanFile:
            Button("Import Now") {
                if let source = model.sources.first { model.importSource(source) }
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
        case .sizeMismatch:
            if let itemID = finding.mediaItemID {
                Button("Accept Disk Size") {
                    try? model.library.acceptDiskSize(for: itemID)
                    reload()
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if tab == .writeback, !runs.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recent runs").modifier(Theme.sectionLabel())
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.scopeDescription)
                                    .font(Theme.ui(11.5))
                                    .foregroundStyle(Theme.Text.secondary)
                                    .lineLimit(1)
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.Text.disabled)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(Theme.Surface.raised))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Safety").modifier(Theme.sectionLabel())
                    ForEach(safetyLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(Theme.Status.green)
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(line)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(Theme.Text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 310)
        .background(Theme.Surface.raised)
    }

    /// Different per tab, always three, always specific.
    private var safetyLines: [String] {
        switch tab {
        case .writeback:
            [
                "Every file's existing embedded tags are snapshotted before it is touched.",
                "A run can be reverted whole, restoring the tags each file had before it.",
                "Files whose container will not accept a tag are skipped and listed, never rewritten.",
            ]
        case .backup:
            [
                "Restoring archives the current file first; it is never deleted.",
                "Close this library's windows before restoring.",
                "Media files are untouched by both backup and restore.",
            ]
        case .validation:
            [
                "A sweep only reads. Findings are the latest run, recomputed cheaply — not a history.",
                "Purging touches only rows already flagged for deletion, and reports files it could not delete rather than assuming.",
                "Items on an offline source are skipped by a purge entirely, so an unplugged drive cannot lose anything.",
            ]
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(planSentence)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            switch tab {
            case .writeback:
                Button("Preview only") { runPreview() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Write tags") { writeTags() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(preview?.writableFiles.isEmpty ?? true)
            case .backup:
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [LibraryDatabase.defaultBackupDirectory()])
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Back up now") { backUp() }
                    .buttonStyle(PrimaryButtonStyle())
            case .validation:
                Button(stagedCount == 0
                    ? "Nothing staged"
                    : "Purge \(stagedCount) staged rows · \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))") {
                    confirmPurge = true
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(stagedCount == 0)
                .confirmationDialog(
                    "Permanently delete \(stagedCount) marked items and their staged files? This cannot be undone.",
                    isPresented: $confirmPurge
                ) {
                    Button("Delete \(stagedCount) Items", role: .destructive) { purge() }
                    Button("Cancel", role: .cancel) {}
                }
                Button(sweeping ? "Sweeping…" : "Run Sweep") { runSweep() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sweeping)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var planSentence: String {
        switch tab {
        case .writeback:
            guard let preview else { return "Preview first — nothing is written until you say so." }
            return "\(preview.writableFiles.count) items · \(preview.fieldCount) tags · \(preview.replacedCount) existing values replaced"
        case .backup:
            return "Backing up copies one file. Your media is never included."
        case .validation:
            return "\(findings.count) findings · a sweep only observes, it never repairs"
        }
    }

    // MARK: - Actions

    private var scopeIDs: [UUID] {
        wholeLibrary
            ? ((try? model.library.writer.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM mediaItem WHERE parentMediaItemID IS NULL")
            }) ?? [])
            : model.visibleItems.map(\.id)
    }

    private func runPreview() {
        previewing = true
        status = nil
        let library = model.library, ids = scopeIDs
        Task.detached(priority: .userInitiated) {
            // Reading each file's current tags is an ffprobe per file —
            // off the main actor, always.
            let result = try? library.previewWriteback(itemIDs: ids)
            await MainActor.run {
                preview = result
                previewing = false
            }
        }
    }

    private func writeTags() {
        guard let preview else { return }
        let ids = preview.writableFiles.map(\.itemID)
        model.writeTags(itemIDs: ids, scope: wholeLibrary
            ? "whole library (\(ids.count) files)"
            : "filtered (\(ids.count) files)")
        status = "Queued — follow it in Background Tasks"
        reload()
    }

    private func backUp() {
        do {
            let url = try model.library.backup(into: LibraryDatabase.defaultBackupDirectory())
            status = "Backed up to \(url.lastPathComponent)"
            errorText = nil
            reload()
        } catch {
            errorText = "Backup failed: \(error)"
        }
    }

    private func runSweep() {
        sweeping = true
        status = nil
        Task {
            await model.runValidation()
            sweeping = false
            reload()
            status = "\(findings.count) findings"
        }
    }

    private func purge() {
        do {
            let outcome = try model.library.purgeDeleted()
            var text = "\(outcome.rowsDeleted) items removed, \(outcome.filesDeleted) files deleted."
            if !outcome.fileFailures.isEmpty {
                text += " \(outcome.fileFailures.count) files could not be deleted and their items were kept."
            }
            status = text
            reload()
            model.refreshAll()
        } catch {
            errorText = "\(error)"
        }
    }

    private func reload() {
        findings = (try? model.library.validationFindings()) ?? []
        backups = LibraryDatabase.backups(in: LibraryDatabase.defaultBackupDirectory())
        runs = (try? model.library.writer.read { db in
            try TagWriteRun.order(sql: "startedAt DESC").limit(6).fetchAll(db)
        }) ?? []
        stagedCount = (try? model.library.writer.read { db in
            try MediaItem.filter(sql: "markedForDeletion = 1").fetchCount(db)
        }) ?? 0
        reclaimable = (try? model.library.reclaimableBytes()) ?? 0
    }
}
