import SwiftUI
import SightsAndSoundsKit

/// The derived-data ledger inside Background Tasks: one row per data
/// kind — content hashes, audio fingerprints, embedded metadata,
/// thumbnails, duplicate check — with the three moves that exist for
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
    @State private var running: Set<SweepKind> = []
    @State private var confirmRecalc: SweepKind?
    @State private var errorText: String?

    enum SweepKind: String, CaseIterable, Identifiable {
        case contentHash, fingerprint, metadata, thumbnails, duplicates
        var id: String { rawValue }

        var title: String {
            switch self {
            case .contentHash: "Content Hashes (MD5)"
            case .fingerprint: "Audio Fingerprints"
            case .metadata: "Embedded Metadata"
            case .thumbnails: "Thumbnails"
            case .duplicates: "Duplicate Check"
            }
        }

        var detail: String {
            switch self {
            case .contentHash: "Identity hash per file — duplicates and the migration boundary key off it."
            case .fingerprint: "Acoustic fingerprints for near-duplicate matching."
            case .metadata: "The ffprobe pairs Tag Analysis mines."
            case .thumbnails: "The grid's stills. Failures self-heal from disk state."
            case .duplicates: "Pairs flagged from hashes and fingerprints. Rejected pairs stay rejected, so there is nothing to recalculate."
            }
        }

        var canRecalculate: Bool { self != .duplicates }
        var canRetry: Bool { self == .contentHash || self == .fingerprint || self == .metadata }
    }

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

    private var openLibraries: [LibraryRef] {
        app.libraries.filter { app.openLibraryIDs.contains($0.id) }
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

            if running.contains(kind) {
                ProgressView().controlSize(.small)
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
        .disabled(running.contains(kind))
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func refreshStatuses() {
        guard let libraryID, let library = try? app.library(for: libraryID) else {
            statuses = [:]
            return
        }
        Task.detached(priority: .utility) {
            var next: [SweepKind: SweepStatus] = [:]
            next[.contentHash] = try? library.contentHashStatus()
            next[.fingerprint] = try? library.fingerprintStatus()
            next[.metadata] = try? library.metadataSweepStatus()
            next[.thumbnails] = try? library.thumbnailStatus(libraryID: libraryID)
            await MainActor.run { statuses = next }
        }
    }

    private func sweep(_ kind: SweepKind, before prepare: @escaping @Sendable (LibraryDatabase) throws -> Void = { _ in }) {
        guard let libraryID,
              let library = try? app.library(for: libraryID),
              let runner = try? app.runner(for: libraryID)
        else { return }
        running.insert(kind)
        errorText = nil
        Task {
            do {
                try prepare(library)
                switch kind {
                case .contentHash:
                    _ = try await runner.enqueueUnlessPending(ContentHashJob.self)
                case .fingerprint:
                    _ = try await runner.enqueueUnlessPending(FingerprintCaptureJob.self)
                case .metadata:
                    _ = try await runner.enqueueUnlessPending(MetadataSweepJob.self)
                case .thumbnails:
                    _ = try await ThumbnailBatchJob.enqueueUnlessPending(on: runner, libraryID: libraryID)
                case .duplicates:
                    _ = try await runner.enqueueUnlessPending(HashDuplicateSweepJob.self)
                    _ = try await runner.enqueueUnlessPending(FingerprintMatchSweepJob.self)
                }
                try await runner.runPending()
            } catch {
                errorText = "\(error)"
            }
            running.remove(kind)
            refreshStatuses()
        }
    }

    private func verify(_ kind: SweepKind) { sweep(kind) }

    private func retryFailed(_ kind: SweepKind) {
        sweep(kind) { library in
            switch kind {
            case .contentHash: try library.retryContentHashFailures()
            case .fingerprint: try library.retryFingerprintFailures()
            case .metadata: try library.retryMetadataSweepFailures()
            case .thumbnails, .duplicates: break
            }
        }
    }

    private func recalculate(_ kind: SweepKind) {
        guard let libraryID else { return }
        sweep(kind) { library in
            switch kind {
            case .contentHash: try library.resetContentHashes()
            case .fingerprint: try library.resetFingerprints()
            case .metadata: try library.resetMetadataSweepAll()
            case .thumbnails: try library.resetThumbnails(libraryID: libraryID)
            case .duplicates: break
            }
        }
    }
}
