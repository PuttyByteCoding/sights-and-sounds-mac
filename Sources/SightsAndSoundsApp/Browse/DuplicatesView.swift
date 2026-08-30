import SwiftUI
import SightsAndSoundsKit

/// The duplicate review queue: pending candidates on the left, the
/// side-by-side compare on the right. Human review absolute — nothing
/// resolves without an explicit Keep or Not Duplicates.
struct DuplicatesView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [DuplicateCandidate] = []
    @State private var itemsByID: [UUID: MediaItem] = [:]
    @State private var selectedID: UUID?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                candidateList
                    .frame(minWidth: 260, maxWidth: 330)
                if let candidate = candidates.first(where: { $0.id == selectedID }),
                   let a = itemsByID[candidate.itemAID],
                   let b = itemsByID[candidate.itemBID] {
                    CompareView(candidate: candidate, itemA: a, itemB: b, onResolved: reload)
                } else {
                    ContentUnavailableView(
                        candidates.isEmpty ? "No Pending Duplicates" : "Select a Pair",
                        systemImage: "rectangle.on.rectangle",
                        description: Text(candidates.isEmpty
                            ? "The sweeps flag identical files and fingerprint matches here."
                            : "Pick a candidate pair to compare."))
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 900, minHeight: 540)
        .onAppear { reload() }
    }

    private var candidateList: some View {
        List(selection: $selectedID) {
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(itemsByID[candidate.itemAID]?.fileName ?? "?")
                        .lineLimit(1)
                    Text(itemsByID[candidate.itemBID]?.fileName ?? "?")
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Label(sourceLabel(candidate), systemImage: sourceIcon(candidate))
                        if let confidence = candidate.confidence {
                            Text(String(format: "%.0f%%", confidence * 100))
                        }
                        if let kind = candidate.matchKind {
                            Text(kind == .sameRecording ? "same recording" : "containment")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(candidate.id)
            }
        }
    }

    private func sourceLabel(_ candidate: DuplicateCandidate) -> String {
        switch candidate.source {
        case .manual: "manual"
        case .fingerprint: "fingerprint"
        case .contentHash: "identical file"
        }
    }

    private func sourceIcon(_ candidate: DuplicateCandidate) -> String {
        switch candidate.source {
        case .manual: "hand.point.right"
        case .fingerprint: "waveform.badge.magnifyingglass"
        case .contentHash: "equal.circle"
        }
    }

    /// The candidate/item fetch runs off the main actor — the sheet's
    /// open used to block on it.
    private func reload() {
        let library = model.library
        Task {
            do {
                let (fetched, items) = try await Task.detached(priority: .userInitiated) {
                    let fetched = try library.pendingCandidates()
                    let ids = Set(fetched.flatMap { [$0.itemAID, $0.itemBID] })
                    let items = try await library.writer.read { db in
                        Dictionary(
                            uniqueKeysWithValues: try MediaItem.fetchAll(db, keys: Array(ids))
                                .map { ($0.id, $0) })
                    }
                    return (fetched, items)
                }.value
                candidates = fetched
                itemsByID = items
                if let selectedID, !candidates.contains(where: { $0.id == selectedID }) {
                    self.selectedID = candidates.first?.id
                } else if selectedID == nil {
                    selectedID = candidates.first?.id
                }
                model.refreshAll()
            } catch {
                errorText = "\(error)"
            }
        }
    }
}

private struct CompareView: View {
    @Environment(BrowseModel.self) private var model
    let candidate: DuplicateCandidate
    let itemA: MediaItem
    let itemB: MediaItem
    let onResolved: () -> Void

    @State private var keeperID: UUID?
    @State private var mergeSelection: Set<UUID> = []
    @State private var mergeableTags: [Tag] = []
    @State private var outcomeText: String?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ComparePane(item: itemA, isKeeper: keeperID == itemA.id) { choose(itemA.id) }
                ComparePane(item: itemB, isKeeper: keeperID == itemB.id) { choose(itemB.id) }
            }
            .padding(.horizontal, 12)

            if let keeperID {
                mergePanel(keeperID: keeperID)
            } else {
                HStack {
                    Text("Choose which file to keep, or mark the pair as not duplicates.")
                        .foregroundStyle(.secondary)
                    Button("Not Duplicates") { reject() }
                }
                .padding(.bottom, 8)
            }

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.callout)
            }
            if let outcomeText {
                Text(outcomeText).font(.callout).foregroundStyle(.secondary)
            }
        }
        .id(candidate.id)
    }

    @ViewBuilder
    private func mergePanel(keeperID: UUID) -> some View {
        let loser = keeperID == itemA.id ? itemB : itemA
        VStack(alignment: .leading, spacing: 6) {
            if !mergeableTags.isEmpty {
                Text("Carry these tags from the file being removed:")
                    .font(.callout)
                FlowRow(spacing: 4) {
                    ForEach(mergeableTags) { tag in
                        Toggle(tag.name, isOn: Binding(
                            get: { mergeSelection.contains(tag.id) },
                            set: { on in
                                if on { mergeSelection.insert(tag.id) } else { mergeSelection.remove(tag.id) }
                            }))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Button("Cancel") { self.keeperID = nil }
                Spacer()
                Button("Not Duplicates") { reject() }
                Button("Confirm — mark “\(loser.fileName)” for deletion", role: .destructive) {
                    decide(keeperID: keeperID, loserID: loser.id)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func choose(_ id: UUID) {
        keeperID = id
        let loserID = id == itemA.id ? itemB.id : itemA.id
        do {
            mergeableTags = try model.library.mergeableTags(keeper: id, loser: loserID)
            mergeSelection = Set(mergeableTags.map(\.id))
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
    }

    private func decide(keeperID: UUID, loserID: UUID) {
        do {
            let outcome = try model.library.decide(
                keeper: keeperID, loser: loserID,
                candidateID: candidate.id, mergeTagIDs: mergeSelection)
            var text = "Kept. \(outcome.tagsMerged) tags carried over."
            if !outcome.skippedSingleValue.isEmpty {
                text += " " + outcome.skippedSingleValue.joined(separator: " ")
            }
            outcomeText = text
            errorText = nil
            onResolved()
        } catch {
            errorText = "\(error)"
        }
    }

    private func reject() {
        do {
            try model.library.rejectCandidate(candidate.id)
            onResolved()
        } catch {
            errorText = "\(error)"
        }
    }
}

private struct ComparePane: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let isKeeper: Bool
    let onKeep: () -> Void

    @State private var thumbnail: NSImage?

    private var score: QualityScoreResult { QualityScore.compute(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Text(item.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(item.relativePath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                metaRow("Duration", item.durationSeconds.map(TransportBarTime.format) ?? "—")
                metaRow("Size", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                if item.kind == .video {
                    metaRow("Resolution", "\(item.width ?? 0)x\(item.height ?? 0)")
                    metaRow("Video", item.videoCodec ?? "—")
                }
                metaRow("Audio", [item.audioCodec, item.sampleRate.map { "\($0) Hz" }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .font(.callout)

            // Quality score with its labeled breakdown.
            HStack(spacing: 6) {
                Text(String(format: "%.0f", score.total))
                    .font(.title2.monospacedDigit().bold())
                Text("/ 100").foregroundStyle(.secondary)
            }
            ForEach(Array(score.components.enumerated()), id: \.offset) { _, component in
                HStack {
                    Text(component.label)
                    Spacer()
                    if component.maxPoints > 0 {
                        Text(String(format: "%.0f/%.0f", component.points, component.maxPoints))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(component.note ?? "")
            }

            HStack {
                Button("Play", systemImage: "play") {
                    // The Duplicates window swaps to the player in place
                    // (AuxiliaryWindowView), same pattern as the library
                    // window — no dismissal needed now that this is a
                    // window, not a sheet.
                    model.playerRequest = PlayerRequest(
                        libraryID: model.libraryID, itemID: item.id, playlist: [item.id])
                }
                .disabled(!model.isOnline(item))
                Spacer()
                Button(isKeeper ? "Keeping This" : "Keep This") { onKeep() }
                    .buttonStyle(.borderedProminent)
                    .tint(isKeeper ? .green : .accentColor)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isKeeper ? Color.green : .clear, lineWidth: 2))
        .task(id: item.id) {
            let data = await ThumbnailProvider.shared.thumbnailData(
                itemID: item.id, libraryID: model.libraryID,
                fileURL: model.fileURL(for: item), durationSeconds: item.durationSeconds)
            thumbnail = data.flatMap(NSImage.init(data:))
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
