import SwiftUI
import SightsAndSoundsKit

/// The cross-library background-tasks dashboard.
///
/// It groups by library because that is what the runner is: one
/// `JobRunner` per library, one job at a time each, three open libraries
/// meaning three queues that cannot race. The lane cards lift each
/// library's *currently running* job out of the chronological list so the
/// state of the machine reads at a glance; the table below stays one
/// stream across every library, which is how you answer "what happened at
/// 9:14".
///
/// Summaries and errors come straight from the job rows — the dashboard
/// states what happened, it never re-derives it.
struct BackgroundTasksView: View {
    @Environment(AppModel.self) private var app

    @State private var lanes: [Lane] = []
    @State private var selectedJob: JobRecord?
    @State private var filter: StateFilter = .all
    @State private var toast: String?

    struct Lane: Identifiable {
        let id: UUID
        let name: String
        var jobs: [JobRecord]
        var isPaused: Bool

        var running: JobRecord? { jobs.first { $0.state == .running } }
        var queued: Int { jobs.count { $0.state == .queued } }
    }

    enum StateFilter: String, CaseIterable {
        case all, active, failed, finished

        var title: String {
            switch self {
            case .all: "All"
            case .active: "Active"
            case .failed: "Failed"
            case .finished: "Finished"
            }
        }

        func admits(_ job: JobRecord) -> Bool {
            switch self {
            case .all: true
            case .active: job.state == .queued || job.state == .running
            case .failed: job.state == .failed
            case .finished: job.state == .succeeded || job.state == .cancelled
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if app.tasksPaused { pausedBanner }
            if !lanes.isEmpty { laneCards }
            HStack(spacing: 0) {
                table
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                inspector
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .defaultToolbarShowsLabels()
        .background(Theme.Surface.content)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.button)
                            .fill(Theme.Surface.iconTile)
                            .stroke(Theme.Border.subtleButtonHover, lineWidth: 1))
                    .padding(.bottom, 24)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            ThemeSegmentedControl(
                selection: $filter,
                options: StateFilter.allCases.map { ($0, $0.title) },
                emphasis: .neutral)
            Text(headline)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.quaternary)
            Spacer()
            Button("Clear finished") { clearFinished() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Removes succeeded and cancelled rows. Failed jobs stay — their evidence is the point.")
            Button(app.tasksPaused ? "Resume all workers" : "Pause all workers") {
                let paused = !app.tasksPaused
                app.setTasksPaused(paused)
                show(paused
                    ? "Workers paused — running jobs finish their current item first"
                    : "Workers resumed")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .help("Hold the queues — the running job finishes, nothing new starts")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var headline: String {
        let jobs = lanes.flatMap(\.jobs)
        return "\(jobs.count { $0.state == .running }) running · "
            + "\(jobs.count { $0.state == .queued }) queued · "
            + "\(jobs.count { $0.state == .failed }) failed"
    }

    /// Paused must be VISIBLE state, not just a toggled button.
    private var pausedBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Theme.Accent.amber)
            Text("Background tasks are paused — queued work waits, the running job finishes.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Status.warnText)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.Surface.selectedRow)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.activeCard).frame(height: 1)
        }
    }

    // MARK: - Lanes

    private var laneCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(lanes) { lane in
                    LaneCard(
                        lane: lane,
                        onPause: { paused in setLanePaused(lane, paused) })
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    // MARK: - Table

    private var visibleJobs: [(job: JobRecord, libraryID: UUID, library: String)] {
        lanes
            .flatMap { lane in lane.jobs.map { ($0, lane.id, lane.name) } }
            .filter { filter.admits($0.0) }
            .sorted { $0.0.createdAt > $1.0.createdAt }
            .map { (job: $0.0, libraryID: $0.1, library: $0.2) }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 22)
                Text("Job").modifier(Theme.sectionLabel()).frame(maxWidth: .infinity, alignment: .leading)
                Text("Library").modifier(Theme.sectionLabel()).frame(width: 132, alignment: .leading)
                Text("Progress").modifier(Theme.sectionLabel()).frame(width: 118, alignment: .leading)
                Text("Elapsed").modifier(Theme.sectionLabel()).frame(width: 92, alignment: .trailing)
                Text("State").modifier(Theme.sectionLabel()).frame(width: 116, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: 31)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            if visibleJobs.isEmpty {
                // An empty window is the healthy state, and should say so.
                VStack(spacing: 6) {
                    Text("Nothing here")
                        .font(Theme.ui(15, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("Workers sleep until there is work. This is the normal state.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleJobs, id: \.job.id) { entry in
                            JobRow(
                                job: entry.job,
                                library: entry.library,
                                selected: selectedJob?.id == entry.job.id,
                                onSelect: { selectedJob = entry.job },
                                onCancel: { cancel(entry.job, in: entry.libraryID) })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let job = selectedJob.flatMap({ selected in
                visibleJobs.first { $0.job.id == selected.id }
            }) {
                JobInspector(
                    job: job.job,
                    library: job.library,
                    onAction: { action in perform(action, on: job.job, in: job.libraryID) })
            } else {
                Text("Select a job to see its timeline, payload and any error.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Text.disabled)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 322)
        .background(Theme.Surface.raised)
    }

    // MARK: - Actions

    private func perform(_ action: JobAction, on job: JobRecord, in libraryID: UUID) {
        switch action {
        case .cancel:
            cancel(job, in: libraryID)
        case .runNext:
            Task {
                guard let runner = try? app.runner(for: libraryID) else { return }
                _ = try? await runner.runNext(job.id)
                // The runner is serialized: this changes what starts
                // next, never what stops.
                show("Moved to the front of this library's queue")
            }
        case .retry, .runAgain:
            Task {
                guard let runner = try? app.runner(for: libraryID) else { return }
                _ = try? await runner.retry(job.id)
                _ = try? await runner.runPending()
                show("Queued again")
            }
        case .copyError:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.error ?? "", forType: .string)
            show("Error copied")
        }
    }

    private func cancel(_ job: JobRecord, in libraryID: UUID) {
        Task {
            guard let runner = try? app.runner(for: libraryID) else { return }
            await runner.requestCancel(job.id)
            show(job.state == .running
                ? "Cancelling after the current item"
                : "Removed from the queue")
        }
    }

    private func clearFinished() {
        Task {
            for lane in lanes {
                guard let runner = try? app.runner(for: lane.id) else { continue }
                _ = try? await runner.deleteFinished()
            }
            await refresh()
            show("Finished jobs cleared from the list")
        }
    }

    private func setLanePaused(_ lane: Lane, _ paused: Bool) {
        Task {
            guard let runner = try? app.runner(for: lane.id) else { return }
            await runner.setPaused(paused)
            if !paused { _ = try? await runner.runPending() }
            await refresh()
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }

    /// The per-library job reads await off the main actor — polling every
    /// registered library once a second must not stutter the app when one
    /// library sits on a sleeping disk. (Opening a not-yet-open handle
    /// still happens on the main actor; handles are cached after that.)
    private func refresh() async {
        var result: [Lane] = []
        for ref in app.libraries {
            guard let library = try? app.library(for: ref.id) else { continue }
            let jobs = (try? await library.writer.read { db in
                try JobRecord.order(sql: "createdAt DESC").limit(40).fetchAll(db)
            }) ?? []
            let paused = await (try? app.runner(for: ref.id))?.isPaused ?? app.tasksPaused
            result.append(Lane(id: ref.id, name: ref.name, jobs: jobs, isPaused: paused))
        }
        lanes = result
    }
}

enum JobAction { case cancel, runNext, retry, runAgain, copyError }

/// One library's lane: what its queue holds, and what it is running.
///
/// Queue depth and "is something running" are two facts — a lane with a
/// live job must never read `idle` because its queue is empty.
private struct LaneCard: View {
    let lane: BackgroundTasksView.Lane
    let onPause: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(lane.name)
                    .font(Theme.ui(12.5, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(lane.queued == 0 ? "no queue" : "\(lane.queued) queued")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.Text.disabled)
                Spacer(minLength: 12)
                Button(lane.isPaused ? "Resume" : "Pause") { onPause(!lane.isPaused) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Hold this library's queue — the running job finishes its current item")
            }
            if let running = lane.running {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(JobNames.displayName(running.kind))
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.Text.secondary)
                        Text(running.kind)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.Text.disabled)
                    }
                    ProgressView(
                        value: Double(running.progressCurrent),
                        total: Double(max(running.progressTotal ?? 1, 1)))
                        .frame(height: 5)
                    Text(progressText(running))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
            } else {
                Text(lane.isPaused ? "paused · waiting for work" : "no job running")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
        }
        .padding(11)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(
                    lane.running != nil ? Theme.Border.activeCard : Theme.Border.standard,
                    lineWidth: 1))
    }

    private var dotColor: Color {
        if lane.isPaused { return Theme.Text.disabled }
        if lane.running != nil { return Theme.Accent.amber }
        return Theme.Border.raised
    }

    private func progressText(_ job: JobRecord) -> String {
        guard let total = job.progressTotal, total > 0 else { return "working…" }
        let percent = Int(Double(job.progressCurrent) / Double(total) * 100)
        return "\(job.progressCurrent) of \(total) · \(percent)%"
    }
}

private struct JobRow: View {
    let job: JobRecord
    let library: String
    let selected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Colour by FAMILY here; the state pill carries the status
            // hue. Two encodings of the same fact in one row is the
            // mistake; two different facts is not.
            Circle()
                .fill(JobNames.familyColor(job.kind))
                .frame(width: 7, height: 7)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(JobNames.displayName(job.kind))
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.primary)
                if let summary = job.summary {
                    Text(summary)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .lineLimit(1)
                } else if let error = job.error {
                    Text(error)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Status.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(library)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            Group {
                if job.state == .running, let total = job.progressTotal, total > 0 {
                    ProgressView(value: Double(job.progressCurrent), total: Double(total))
                } else if let total = job.progressTotal, total > 0 {
                    Text("\(job.progressCurrent)/\(total)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.disabled)
                } else {
                    Text("—")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.zeroCount)
                }
            }
            .frame(width: 118, alignment: .leading)
            Text(elapsed)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Text.disabled)
                .frame(width: 92, alignment: .trailing)
            HStack(spacing: 6) {
                StatePill(state: job.state)
                if job.state == .queued || job.state == .running {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 116, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(selected ? Theme.Surface.selectedSegment : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Theme.Accent.amber)
                    .frame(width: Theme.Border.selectionInsetWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// Derived from the clock, never a ticking counter — three separate
    /// timer bugs in this project came from counters that died on a
    /// remount or rewound on a pause.
    private var elapsed: String {
        guard let started = job.startedAt else { return "—" }
        let end = job.finishedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(started))
        let m = seconds / 60, s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

private struct StatePill: View {
    let state: JobState

    var body: some View {
        Text(label)
            .font(Theme.ui(9, .bold))
            .foregroundStyle(color)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(color.opacity(0.15)))
    }

    private var label: String {
        switch state {
        case .queued: "QUEUED"
        case .running: "RUNNING"
        case .succeeded: "DONE"
        case .failed: "FAILED"
        case .cancelled: "CANCELLED"
        }
    }

    private var color: Color {
        switch state {
        case .queued: Theme.Text.quaternary
        case .running: Theme.Accent.amber
        case .succeeded: Theme.Status.green
        case .failed: Theme.Status.red
        case .cancelled: Theme.Text.disabled
        }
    }
}

/// Everything the row could not fit: the raw kind you grep the log for,
/// the full error rather than its one-line truncation, the timeline, and
/// the payload. Retry becomes a decision instead of a guess.
private struct JobInspector: View {
    let job: JobRecord
    let library: String
    let onAction: (JobAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(JobNames.displayName(job.kind))
                        .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                        .foregroundStyle(Theme.Text.primary)
                    Text(job.kind)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.disabled)
                        .textSelection(.enabled)
                    Text(library)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Text.quaternary)
                }

                if let summary = job.summary {
                    block(title: "Outcome", body: summary, tint: Theme.Text.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeline").modifier(Theme.sectionLabel())
                    timelineRow("created", job.createdAt)
                    timelineRow("started", job.startedAt)
                    timelineRow("finished", job.finishedAt)
                }

                if let error = job.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error").modifier(Theme.sectionLabel(Theme.Status.red))
                        Text(error)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.Status.redBright)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(Theme.Surface.well)
                                    .stroke(Theme.Status.red.opacity(0.35), lineWidth: 1))
                    }
                }

                if let payload = job.payload, let text = String(data: payload, encoding: .utf8) {
                    block(title: "Payload", body: text, tint: Theme.Text.quaternary)
                }

                VStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button(label(for: action)) { onAction(action) }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(14)
        }
    }

    /// Actions follow state, and stay visible when unavailable.
    private var actions: [JobAction] {
        switch job.state {
        case .running: [.cancel]
        case .queued: [.runNext, .cancel]
        case .failed, .cancelled: [.retry, .copyError]
        case .succeeded: [.runAgain]
        }
    }

    private func label(for action: JobAction) -> String {
        switch action {
        case .cancel: job.state == .running ? "Cancel job" : "Remove from queue"
        case .runNext: "Run next"
        case .retry: "Retry"
        case .runAgain: "Run again"
        case .copyError: "Copy error"
        }
    }

    private func timelineRow(_ label: String, _ date: Date?) -> some View {
        HStack {
            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            Text(date?.formatted(date: .abbreviated, time: .standard) ?? "—")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Text.quaternary)
        }
    }

    private func block(title: String, body text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).modifier(Theme.sectionLabel())
            Text(text)
                .font(Theme.mono(10.5))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
        }
    }
}

/// The app's ONLY source of job labels — the tasks window, import
/// history, and any toast that names a job all read this. A second
/// mapping is how two windows come to call the same job different things.
enum JobNames {
    static func displayName(_ kind: String) -> String {
        switch kind {
        case ImportJob.kind: "Import"
        case ContentHashJob.kind: "Content hashing"
        case ThumbnailBatchJob.kind: "Thumbnail generation"
        case HashDuplicateSweepJob.kind: "Duplicate check (hashes)"
        case FingerprintCaptureJob.kind: "Audio fingerprinting"
        case FingerprintMatchSweepJob.kind: "Duplicate check (fingerprints)"
        case ClipExportJob.kind: "Clip export"
        case RemuxJob.kind: "Remux"
        case EncodeJob.kind: "Encode"
        case BlockRemovalJob.kind: "Block removal"
        case OcrJob.kind: "Text scan (OCR)"
        case JoinJob.kind: "Join"
        case ReorganizeJob.kind: "Reorganize"
        case WritebackJob.kind: "Tag write-back"
        case RestoreTagsJob.kind: "Tag restore"
        case ValidationJob.kind: "Validation"
        default: kind
        }
    }

    /// Colour by family, derived from the kind's prefix — ingest,
    /// duplicates, operations, write-back, validation.
    static func familyColor(_ kind: String) -> Color {
        switch kind.split(separator: ".").first.map(String.init) ?? "" {
        case "import", "hash", "thumbnail": Theme.Segment.song
        case "duplicates", "fingerprint": Theme.Status.mauve
        case "writeback", "restore": Theme.Accent.amber
        case "validation": Color(hex: 0x9DBF7F)
        default: Color(hex: 0x8B93E8)
        }
    }
}
