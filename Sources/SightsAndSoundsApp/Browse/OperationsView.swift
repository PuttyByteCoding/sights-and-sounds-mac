import SwiftUI
import SightsAndSoundsKit

/// What an operation will do to a selection, before it does it.
///
/// Every operation already exists as a job, and the grid's context menu
/// already names them all — those strings are used verbatim here. What
/// was missing is the step between choosing one and it running: what
/// gets written, how big it will be, how long it takes, and what happens
/// to the original.
///
/// The context menu still handles the one-item case. This window is for
/// a selection.
struct OperationsView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app

    let itemIDs: [UUID]

    @State private var items: [MediaItem] = []
    @State private var excluded: Set<UUID> = []
    @State private var operation: Operation = .optimize
    @State private var preset: EncodeJob.Preset = .h264
    @State private var remuxMode: RemuxJob.Mode = .optimize
    @State private var ocr = AppSettingsStore.shared.current.ocr
    @State private var ocrInterval = AppSettingsStore.shared.current.ocrSampleIntervalSeconds
    @State private var joinOrder: [UUID] = []
    @State private var status: String?

    /// The rows the operation will act on. Unticking recomputes every
    /// number — nothing here hardcodes its own count.
    private var included: [MediaItem] {
        items.filter { !excluded.contains($0.id) && operation.accepts($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                operationList
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                centre
                Rectangle().fill(Theme.Border.standard).frame(width: 1)
                inspector
            }
            footer
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Theme.Surface.content)
        .task { await load() }
    }

    // MARK: - Operation list

    private var operationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Operations").modifier(Theme.sectionLabel())
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Operation.allCases, id: \.self) { entry in
                        operationRow(entry)
                    }
                }
            }
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            Text("Each runs as a background job on this library's queue, one at a time.")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 250)
        .background(Theme.Surface.sidebar)
    }

    private func operationRow(_ entry: Operation) -> some View {
        let requirement = entry.unmetRequirement(for: items)
        let selected = operation == entry
        return Button {
            operation = entry
            if entry == .join { joinOrder = included.map(\.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(Theme.ui(12.5, selected ? .semibold : .regular))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    kindChip(entry.kind)
                }
                // Unavailable, not hidden: the requirement goes where the
                // description goes, because hiding the row teaches
                // nothing about why it is missing.
                Text(requirement ?? entry.produces)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(requirement == nil ? Theme.Text.disabled : Theme.Status.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .opacity(requirement == nil ? 1 : 0.5)
            .background(selected ? Theme.Surface.selectedRow : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Theme.Accent.amber)
                        .frame(width: Theme.Border.selectionInsetWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Stream copy versus re-encode belongs on the row: it decides how
    /// freely each can be used.
    private func kindChip(_ kind: Operation.Kind) -> some View {
        Text(kind.label)
            .font(Theme.ui(9, .bold))
            .foregroundStyle(kind.color)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(kind.color.opacity(0.15)))
    }

    // MARK: - Centre

    private var centre: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(operation.title)
                        .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                        .foregroundStyle(Theme.Text.primary)
                    Text(operation.blurb)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                controls
                if operation == .join, let report = joinReport, !report.isJoinable {
                    refusal(report)
                }
                inputOutputList
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var controls: some View {
        switch operation {
        case .encode:
            ThemeSegmentedControl(
                selection: $preset,
                options: EncodeJob.Preset.allCases.map { ($0, $0.displayName) },
                emphasis: .neutral)
        case .optimize, .repair:
            ThemeSegmentedControl(
                selection: $remuxMode,
                options: [(RemuxJob.Mode.optimize, "Optimize"), (.repair, "Repair")],
                emphasis: .neutral)
        case .join:
            VStack(alignment: .leading, spacing: 6) {
                Text("Drag to reorder — this is the order they will play in.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.disabled)
                ForEach(orderedJoinParts) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(Theme.ui(9))
                            .foregroundStyle(Theme.Text.disabled)
                        Text(item.fileName)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            move(item, by: -1)
                        } label: { Image(systemName: "arrow.up").font(Theme.ui(9)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.quaternary)
                        Button {
                            move(item, by: 1)
                        } label: { Image(systemName: "arrow.down").font(Theme.ui(9)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Text.quaternary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.raised))
                }
            }
        case .ocr:
            OcrControls(settings: $ocr, interval: $ocrInterval, frames: ocrFrames)
        default:
            EmptyView()
        }
    }

    private func refusal(_ report: JoinJob.CompatibilityReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ffmpeg refuses this join")
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(Theme.Status.redBright)
            ForEach(report.mismatches, id: \.self) { mismatch in
                Text("· \(mismatch)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.Status.red)
            }
            Text(JoinJob.CompatibilityReport.remedy)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Status.red.opacity(0.08))
                .stroke(Theme.Status.red.opacity(0.35), lineWidth: 1))
    }

    /// The selection IS the list: each row is an input with its predicted
    /// output beside it, and unticking recomputes every number.
    private var inputOutputList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 26)
                Text("Source").modifier(Theme.sectionLabel())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 26)
                Text("Writes").modifier(Theme.sectionLabel())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            ForEach(items) { item in
                let accepted = operation.accepts(item)
                let on = accepted && !excluded.contains(item.id)
                HStack(spacing: 0) {
                    Button {
                        guard accepted else { return }
                        if excluded.contains(item.id) {
                            excluded.remove(item.id)
                        } else {
                            excluded.insert(item.id)
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .fill(on ? Theme.Accent.amber : .clear)
                            .stroke(
                                on ? Theme.Accent.amber : Theme.Border.subtleButtonHover,
                                lineWidth: 1)
                            .frame(width: 13, height: 13)
                    }
                    .buttonStyle(.plain)
                    .disabled(!accepted)
                    .frame(width: 26, alignment: .leading)
                    Text(item.fileName)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("→")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                        .frame(width: 26)
                    Text(accepted ? operation.output(for: item) : "unavailable")
                        .font(Theme.mono(11))
                        .foregroundStyle(accepted ? Theme.Status.green : Theme.Status.redBright)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .opacity(on ? 1 : 0.45)
            }
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What this costs").modifier(Theme.sectionLabel())
                    costRow("files written", "\(estimate.filesWritten)")
                    if operation == .ocr {
                        costRow("frames read", "\(ocrFrames)")
                    } else {
                        costRow(
                            "added to disk",
                            "≈ " + ByteCountFormatter.string(
                                fromByteCount: estimate.bytesAdded, countStyle: .file))
                    }
                    costRow(estimate.timeLabel, "≈ " + durationText(estimate.seconds))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Guarantees").modifier(Theme.sectionLabel())
                    ForEach(operation.guarantees, id: \.self) { line in
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
                VStack(alignment: .leading, spacing: 5) {
                    Text("Command").modifier(Theme.sectionLabel())
                    // The command tells someone who knows ffmpeg more
                    // than three paragraphs can, and tells someone who
                    // does not that this is a plain, inspectable thing.
                    Text(operation.command(preset: preset, mode: remuxMode))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.Text.quaternary)
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
            .padding(14)
        }
        .frame(width: 296)
        .background(Theme.Surface.raised)
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            Text(value)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
            Spacer()
            if let status {
                Text(status)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Accent.amber)
            }
            Button(runnable ? "\(operation.verb) \(included.count) Files" : operation.blockedLabel(for: items)) {
                run()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!runnable)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var runnable: Bool {
        guard operation.unmetRequirement(for: items) == nil, !included.isEmpty else { return false }
        if operation == .join { return joinReport?.isJoinable ?? false }
        return true
    }

    private var summary: String {
        if let requirement = operation.unmetRequirement(for: items) { return requirement }
        if operation == .join, let report = joinReport, !report.isJoinable {
            return "Nothing will be written — the parts do not match."
        }
        return operation.summary(count: included.count)
    }

    // MARK: - Derived

    private var joinReport: JoinJob.CompatibilityReport? {
        operation == .join ? JoinJob.compatibility(of: orderedJoinParts) : nil
    }

    private var orderedJoinParts: [MediaItem] {
        let byID = Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0) })
        let ordered = joinOrder.compactMap { byID[$0] }
        let rest = included.filter { !joinOrder.contains($0.id) }
        return ordered + rest
    }

    private var ocrFrames: Int {
        OperationEstimates.ocrFrames(
            durations: included.compactMap(\.durationSeconds),
            sampleIntervalSeconds: ocrInterval)
    }

    private var estimate: OperationEstimate {
        operation.estimate(for: included, preset: preset, ocr: ocr, interval: ocrInterval)
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    private func move(_ item: MediaItem, by delta: Int) {
        var order = orderedJoinParts.map(\.id)
        guard let index = order.firstIndex(of: item.id) else { return }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        joinOrder = order
    }

    // MARK: - Running

    private func run() {
        guard let runner = try? app.runner(for: model.libraryID) else { return }
        let targets = included
        let operation = operation, preset = preset, mode = remuxMode
        let ocr = ocr, interval = ocrInterval
        let order = orderedJoinParts.map(\.id)
        Task {
            do {
                try await operation.enqueue(
                    targets, order: order, on: runner, preset: preset, mode: mode,
                    ocr: ocr, interval: interval)
                _ = try await runner.runPending()
                status = "Queued on this library — follow it in Background Tasks"
                model.refreshAll()
            } catch {
                status = "\(error)"
            }
        }
    }

    private func load() async {
        let library = model.library, ids = itemIDs
        let fetched = (try? await library.writer.read { db in
            try MediaItem.fetchAll(db, keys: ids)
        }) ?? []
        let position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        items = fetched.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        joinOrder = items.map(\.id)
    }
}

/// OCR's six knobs, with the frame count beside them — because every one
/// of them changes what a scan costs, and half-second sampling across
/// four concerts is thirty-four thousand frames.
private struct OcrControls: View {
    @Binding var settings: OcrSettings
    @Binding var interval: Double
    let frames: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            control("Sample every", note: "How often a frame is read. Text on screen for less than this can be missed entirely.") {
                HStack(spacing: 8) {
                    Slider(value: $interval, in: 0.5...30, step: 0.5)
                        .frame(width: 180)
                    Text(String(format: "%.1fs", interval))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            control("Recognition", note: nil) {
                ThemeSegmentedControl(
                    selection: $settings.recognitionLevel,
                    options: OcrSettings.RecognitionLevel.allCases.map { ($0, $0.displayName) },
                    emphasis: .neutral)
            }
            control("Smallest text", note: "As a share of frame height. Lower catches captions and credits; it also catches noise.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.minimumTextHeight, in: 0.005...0.2)
                        .frame(width: 180)
                    Text(String(format: "%.1f%%", settings.minimumTextHeight * 100))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.secondary)
                }
            }
            control("Region", note: "Restrict where text is looked for. A stage banner lives up top; a caption lives at the bottom.") {
                ThemeSegmentedControl(
                    selection: regionChoice,
                    options: [("full", "Whole frame"), ("top", "Top third"), ("bottom", "Bottom third")],
                    emphasis: .neutral)
            }
            control("Correction", note: "Vision guesses at plausible misreads. Off is literal — better when the text is a band name it will not know.") {
                Toggle(isOn: $settings.usesLanguageCorrection) {
                    Text("Language correction").font(Theme.ui(12))
                }
                .toggleStyle(.checkbox)
            }
            control("Repeats", note: "The same banner across 200 frames is 200 identical lines unless they are collapsed.") {
                Toggle(isOn: $settings.collapseRepeats) {
                    Text("Collapse consecutive repeats").font(Theme.ui(12))
                }
                .toggleStyle(.checkbox)
            }
            Text("\(frames) frames read at these settings")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Accent.amber)
        }
        .foregroundStyle(Theme.Text.secondary)
    }

    private var regionChoice: Binding<String> {
        Binding(
            get: {
                if settings.region.isFull { return "full" }
                return settings.region.y > 0.5 ? "top" : "bottom"
            },
            set: { choice in
                switch choice {
                case "top": settings.region = .init(x: 0, y: 0.66, width: 1, height: 0.34)
                case "bottom": settings.region = .init(x: 0, y: 0, width: 1, height: 0.34)
                default: settings.region = .full
                }
            })
    }

    private func control<Content: View>(
        _ label: String, note: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).modifier(Theme.sectionLabel())
            content()
            if let note {
                Text(note)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
