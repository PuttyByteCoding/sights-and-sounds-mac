import SwiftUI
import SightsAndSoundsKit

/// The cross-library background-tasks dashboard: every registered
/// library's job table, refreshing while visible, with cancellation for
/// pending work. Summaries come straight from the job rows — the
/// dashboard states what happened, it never re-derives it.
struct BackgroundTasksView: View {
    @Environment(AppModel.self) private var app
    @State private var sections: [LibrarySection] = []

    struct LibrarySection: Identifiable {
        let id: UUID
        let name: String
        var jobs: [JobRecord]
    }

    var body: some View {
        Group {
            if sections.allSatisfy(\.jobs.isEmpty) {
                ContentUnavailableView(
                    "No Background Tasks", systemImage: "tray",
                    description: Text("Imports, hashing and thumbnail sweeps appear here."))
            } else {
                List {
                    ForEach(sections) { section in
                        if !section.jobs.isEmpty {
                            Section(section.name) {
                                ForEach(section.jobs) { job in
                                    JobRow(job: job, libraryID: section.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        var result: [LibrarySection] = []
        for ref in app.libraries {
            guard let library = try? app.library(for: ref.id) else { continue }
            let jobs = (try? library.writer.read { db in
                try JobRecord.order(sql: "createdAt DESC").limit(30).fetchAll(db)
            }) ?? []
            result.append(LibrarySection(id: ref.id, name: ref.name, jobs: jobs))
        }
        sections = result
    }
}

private struct JobRow: View {
    @Environment(AppModel.self) private var app
    let job: JobRecord
    let libraryID: UUID

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                HStack(spacing: 8) {
                    if job.state == .running, let total = job.progressTotal, total > 0 {
                        ProgressView(value: Double(job.progressCurrent), total: Double(total))
                            .frame(width: 140)
                        Text("\(job.progressCurrent)/\(total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if let summary = job.summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    } else if let error = job.error {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            Spacer()
            Text(job.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if job.state == .queued || job.state == .running {
                Button("Cancel") {
                    Task { await (try? app.runner(for: libraryID))?.requestCancel(job.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        switch job.kind {
        case ImportJob.kind: "Import"
        case ContentHashJob.kind: "Content hashing"
        case ThumbnailBatchJob.kind: "Thumbnail generation"
        case HashDuplicateSweepJob.kind: "Duplicate check (hashes)"
        case FingerprintCaptureJob.kind: "Audio fingerprinting"
        case FingerprintMatchSweepJob.kind: "Duplicate check (fingerprints)"
        default: job.kind
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
