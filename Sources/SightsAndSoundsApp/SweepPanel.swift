import SwiftUI
import SightsAndSoundsKit

/// The derived-data ledger inside Background Tasks: one row per data
/// kind — content hashes, audio fingerprints, embedded metadata,
/// media signal, thumbnails, duplicate check — with the three moves that exist for
/// every sweep in the app:
///
/// **Verify** runs the sweep as-is, which fills MISSING data only.
/// **Retry failed** deletes the failure rows first — a failure row is
/// what stops a sweep re-probing a broken file forever, so retry IS row
/// deletion. **Recalculate all** forgets the data itself, then sweeps.
struct SweepPanel: View {
    @Environment(AppModel.self) private var app

    @State private var libraryID: UUID?
    @State private var statuses: [SweepKind: SweepStatus] = [:]
    /// Per library: the picker can switch libraries while a sweep runs,
    /// and a row showed another library's sweep as its own (and the pause
    /// watch read the wrong library's queue).
    @State private var running: [UUID: Set<SweepKind>] = [:]
    @State private var queuePaused = false
    /// Only the newest read lands: an older one — another library before
    /// the picker changed, or a slower read of this one — finished last
    /// and put its counts under the library on screen.
    @State private var statusGeneration = 0

    private var runningHere: Set<SweepKind> { libraryID.flatMap { running[$0] } ?? [] }
    @State private var confirmRecalc: SweepKind?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Sweeps").modifier(Theme.sectionLabel())
                Picker("", selection: $libraryID) {
                    ForEach(openLibraries) { library in
                        Text(library.name).tag(UUID?.some(library.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let errorText {
                    Text(errorText)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.Status.orange)
                }
            }

            if libraryID == nil {
                Text("Open a library to run its sweeps.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.quaternary)
            } else {
                ForEach(SweepKind.allCases) { kind in
                    row(kind)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Surface.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
        .task {
            if libraryID == nil { libraryID = openLibraries.first?.id }
            refreshStatuses()
        }
        .onChange(of: libraryID) { _, _ in refreshStatuses() }
        .watchingQueuePause($queuePaused, while: !runningHere.isEmpty, libraryID: libraryID)
        .confirmationDialog(
            "Recalculate \(confirmRecalc?.title ?? "")?",
            isPresented: Binding(
                get: { confirmRecalc != nil },
                set: { if !$0 { confirmRecalc = nil } })
        ) {
            Button("Forget and Recalculate", role: .destructive) {
                if let kind = confirmRecalc { recalculate(kind) }
            }
        } message: {
            Text("Every item's stored data for this kind is forgotten, then the sweep rebuilds it. Nothing else is touched.")
        }
    }

    /// The libraries with a window open, on this Mac or another: a
    /// sweep is the library's own work, done where its files are.
    private var openLibraries: [AppModel.OpenLibrary] {
        app.openLibraries(withAWindow: true)
    }

    private func row(_ kind: SweepKind) -> some View {
        let status = statuses[kind]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(Theme.ui(Theme.TypeScale.body, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(kind.detail)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
            }
            Spacer(minLength: 8)

            if let status {
                Text("\(status.missing) missing")
                    .font(Theme.mono(10))
                    .foregroundStyle(
                        status.missing == 0 ? Theme.Text.zeroCount : Theme.Status.warnText)
                Text("\(status.failed) failed")
                    .font(Theme.mono(10))
                    .foregroundStyle(
                        status.failed == 0 ? Theme.Text.zeroCount : Theme.Status.red)
            }

            if runningHere.contains(kind) {
                if queuePaused {
                    Text("tasks paused")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.disabled)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button("Verify") { verify(kind) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Run the sweep — fills missing data, touches nothing that exists")
            Button("Retry Failed") { retryFailed(kind) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(!kind.canRetry || (statuses[kind]?.failed ?? 0) == 0)
                .help(kind.canRetry
                    ? "Clear the failure rows, then sweep — broken files get one more chance"
                    : "This sweep records no failures")
            Button("Recalculate All") { confirmRecalc = kind }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(!kind.canRecalculate)
                .help(kind.canRecalculate
                    ? "Forget every item's stored data for this kind, then rebuild"
                    : "Rejected pairs stay rejected — rerunning the check is Verify")
        }
        .disabled(runningHere.contains(kind))
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func refreshStatuses() {
        statusGeneration += 1
        let generation = statusGeneration
        guard let libraryID, let service = try? app.service(for: libraryID) else {
            statuses = [:]
            return
        }
        Task {
            let next = (try? await service.sweepStatuses()) ?? [:]
            guard generation == statusGeneration else { return }
            statuses = next
        }
    }

    private func sweep(_ kind: SweepKind, after preparation: SweepPreparation = .nothing) {
        guard let libraryID, let service = try? app.service(for: libraryID) else { return }
        running[libraryID, default: []].insert(kind)
        errorText = nil
        Task {
            do {
                try await service.startSweep(kind, after: preparation)
                // This row's sweep, not the whole queue: each row stayed
                // "running" until every other sweep queued had finished.
                try await Self.waitUntilNonePending(of: kind, on: service)
            } catch {
                errorText = "\(error)"
            }
            running[libraryID]?.remove(kind)
            refreshStatuses()
        }
    }

    /// Returns when none of a sweep's jobs is queued or running. Asked
    /// of the service on a timer rather than waited for in one request:
    /// a sweep of a large library takes hours, and the library may be on
    /// another Mac.
    static func waitUntilNonePending(
        of kind: SweepKind, on service: any LibraryService, every interval: Duration = .seconds(1)
    ) async throws {
        for jobKind in kind.jobKinds {
            while try await service.jobQueue(kind: jobKind, startingQueue: false).pendingCount > 0 {
                try await Task.sleep(for: interval)
            }
        }
    }

    private func verify(_ kind: SweepKind) { sweep(kind) }

    private func retryFailed(_ kind: SweepKind) { sweep(kind, after: .forgetFailures) }

    private func recalculate(_ kind: SweepKind) { sweep(kind, after: .forgetEverything) }
}

extension SweepKind {
    var title: String {
        switch self {
        case .contentHash: "Content Hashes (MD5)"
        case .fingerprint: "Audio Fingerprints"
        case .metadata: "Embedded Metadata"
        case .signal: "Media Signal"
        case .thumbnails: "Thumbnails"
        case .duplicates: "Duplicate Check"
        }
    }

    var detail: String {
        switch self {
        case .contentHash: "Identity hash per file — duplicates and the migration boundary key off it."
        case .fingerprint: "Acoustic fingerprints for near-duplicate matching."
        case .metadata: "The ffprobe pairs Tag Analysis mines."
        case .signal: "What each file declares about its encoding, and how its frames are really timed."
        case .thumbnails: "The grid's stills. A file with no frame to show is skipped until retried."
        case .duplicates: "Pairs flagged from hashes and fingerprints. Rejected pairs stay rejected, so there is nothing to recalculate."
        }
    }
}
