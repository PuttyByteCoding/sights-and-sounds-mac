import SwiftUI
import SightsAndSoundsKit

/// Reorganising, and the history that makes it safe to do.
///
/// They were two sheets. The history is the reason a template can be run
/// at all — a bad one is a session to put back rather than a restore from
/// backup — so they are two tabs of one window rather than two things to
/// find.
struct OrganiseView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(AppModel.self) private var app

    enum Tab: String, CaseIterable {
        case plan, history

        var title: String {
            switch self {
            case .plan: "Reorganise"
            case .history: "Move history"
            }
        }
    }

    @State private var tab: Tab = .plan
    @State private var template = "%Band/%Year"
    /// The plan, made off the main actor.
    @State private var planner = OrganisePlanner()
    @State private var sessions: [LibraryDatabase.MoveSession] = []
    @State private var status: String?
    @State private var errorText: String?
    /// Move is being queued.
    @State private var applying = false
    /// A reorganize of this library is queued or running — from this
    /// window or any other. Move waits for it: behind a long queue the plan
    /// on screen would otherwise offer the same moves again, and a second
    /// run with an edited template would move the files twice, into a
    /// session whose put-back restores the first layout, not the original.
    @State private var movesPending = false
    /// This library's runner is paused (globally, or its lane from Background
    /// Tasks), so queued moves will not run until it resumes.
    @State private var queuePaused = false
    /// The grid's items when the window opened; nil is the whole library.
    let scope: [UUID]?

    private var scopeIDs: [UUID] { scope ?? model.visibleItems.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .plan: planTab
            case .history: historyTab
            }
        }
        .frame(minWidth: 940, minHeight: 580)
        .background(Theme.Surface.content)
        .onAppear {
            preview()
            reloadHistory()
        }
        // Unscoped, the plan is over the listing — which lands after the
        // window opens. It used to stay on "Nothing to move". Watched in a
        // child, so a listing refresh does not re-render this window.
        .background {
            if scope == nil { ListingSizeWatch(model: model) { preview(settle: .milliseconds(300)) } }
        }
        // Whether a reorganize of this library is waiting, from any window:
        // Move waits for it. Observed, not polled, and it stops with the
        // window. Seeing one starts the queue unless tasks are paused.
        .task {
            guard let runner = try? app.runner(for: model.libraryID) else { return }
            do {
                for try await count in OrganiseMove.pending(in: model.library, runner: runner) {
                    movesPending = count > 0
                    // The queue has confirmed the moves: Move can stop
                    // saying it is queueing them.
                    if count > 0 { applying = false }
                }
            } catch {
                movesPending = false
            }
        }
        // Pausing writes nothing to the queue, so the observation above
        // cannot see it. Only while moves wait, the runner's own flag is
        // read every two seconds — the per-library pause lives there, not
        // in the app-wide one.
        .task(id: movesPending) {
            guard movesPending, let runner = try? app.runner(for: model.libraryID) else {
                queuePaused = false
                return
            }
            while !Task.isCancelled {
                queuePaused = await runner.isPaused
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Moves (a revert from another window, a run finishing) change
        // the history and what the plan would do.
        .followsLibraryChanges(model, [.items]) {
            reloadHistory()
            preview(settle: .milliseconds(300))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ThemeSegmentedControl(
                selection: $tab,
                options: Tab.allCases.map { ($0, $0.title) },
                emphasis: .neutral)
            Group {
                switch (tab, scope) {
                case (.plan, nil):
                    // Unscoped, the count is the listing's; only this
                    // child follows it.
                    WholeListingHeadline(model: model)
                case (.plan, let scope?):
                    // Scope is the grid's filter, and it says so — rather
                    // than leaving someone to discover that their filter
                    // was the selection.
                    Text("applies to the \(scope.count) items the grid showed when this window opened")
                case (.history, _):
                    Text(historyHeadline)
                }
            }
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    /// Says why Move is unavailable: moves already queued, or a newer
    /// plan still being made.
    private var moveTitle: String {
        if movesPending { return queuePaused ? "Moves queued — tasks paused" : "Moves queued…" }
        if !planner.isCurrent { return "Updating plan…" }
        let count = planner.plan.movableCount
        return count == 0 ? "Nothing to move" : "Move \(count) items"
    }

    private var historyHeadline: String {
        "\(sessions.count) sessions · \(sessions.reduce(0) { $0 + $1.logs.count }) moves logged"
    }

    // MARK: - Plan

    private var planTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                templateBlock
                planTable
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.Border.standard).frame(width: 1)
            planSidebar
        }
    }

    private var templateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The template field is the most important control in the
            // window, and reads as one.
            TextField("Template", text: $template)
                .textFieldStyle(.plain)
                .font(Theme.mono(14))
                .foregroundStyle(Theme.Accent.amber)
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.activeCard, lineWidth: 1))
                .onChange(of: template) { preview(settle: .milliseconds(150)) }

            // Tokens are inserted, not memorised.
            FlowRow(spacing: 5) {
                ForEach(model.vocabulary) { entry in
                    Button {
                        template += "%" + entry.category.name.replacingOccurrences(of: " ", with: "_")
                    } label: {
                        Text("%" + entry.category.name.replacingOccurrences(of: " ", with: "_"))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.categoryHue(entry.category.colorIndex))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(
                                Capsule().fill(
                                    Theme.categoryHue(entry.category.colorIndex).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    template += "/"
                } label: {
                    Text("/")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.Text.quaternary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Theme.Surface.iconTile))
                }
                .buttonStyle(.plain)
                .help("Anything not starting with % is used literally — Shows/%Year works")
            }

            Text("A token names a category; underscores stand in for spaces. Anything else is literal, and a slash makes a level.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(planner.validationErrors, id: \.self) { error in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Theme.Status.red).frame(width: 5, height: 5).padding(.top, 5)
                    Text(error)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Status.redBright)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var planTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(planner.plan, id: \.itemID) { entry in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(entry.toFolder == nil ? Theme.Text.disabled : Theme.Status.green)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.fileName)
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.Text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.fromFolder.isEmpty ? "(root)" : entry.fromFolder)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.Text.disabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if let to = entry.toFolder {
                                Text(to)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.Status.greenBright)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                // A skipped item needs nothing undone:
                                // tag it and run again.
                                Text("stays where it is")
                                    .font(Theme.ui(11))
                                    .foregroundStyle(Theme.Text.disabled)
                                if let reason = entry.reason {
                                    Text(reason)
                                        .font(Theme.ui(10.5))
                                        .foregroundStyle(Theme.Status.orangeMuted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(entry.toFolder == nil ? Theme.Surface.raised : .clear)
                }
            }
        }
    }

    private var planSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This plan").modifier(Theme.sectionLabel())
                        stat("\(planner.plan.movableCount)", "items would move")
                        stat("\(planner.plan.count - planner.plan.movableCount)", "skipped, left untouched")
                        stat("\(planner.plan.foldersCreated.count)", "folders created")
                    }
                    if !planner.plan.skipReasons.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Why items are skipped").modifier(Theme.sectionLabel())
                            ForEach(planner.plan.skipReasons, id: \.reason) { entry in
                                HStack {
                                    Text("\(entry.count)")
                                        .font(Theme.mono(10.5))
                                        .foregroundStyle(Theme.Status.orangeMuted)
                                    Text("· \(entry.reason)")
                                        .font(Theme.ui(11))
                                        .foregroundStyle(Theme.Text.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Text("A skipped item is left exactly where it is. Tag it and run the plan again — nothing has to be undone first.")
                                .font(Theme.ui(10.5))
                                .foregroundStyle(Theme.Text.disabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !planner.plan.foldersCreated.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Folders this creates").modifier(Theme.sectionLabel())
                            ForEach(planner.plan.foldersCreated, id: \.folder) { entry in
                                HStack {
                                    Text(entry.folder)
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.Text.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("\(entry.count)")
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.Text.disabled)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Button(moveTitle) {
                    apply()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(applying || movesPending || !planner.isCurrent || planner.plan.movableCount == 0 || !planner.validationErrors.isEmpty)
                Text("Runs as a background job. Each move is logged individually, so a bad template is one session to put back rather than a restore from backup.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(Theme.Surface.raised)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(Theme.mono(15, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
        }
    }

    // MARK: - History

    private var historyTab: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("No Moves Yet")
                        .font(Theme.ui(15, .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                    Text("Staging, reorganization and manual moves appear here, each revertible.")
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.Text.disabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(sessions) { session in
                            sessionCard(session)
                        }
                        Text("Reverting is one-shot per move — a move that has been put back cannot be put back again, and the entry stays as the record that it happened.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                }
            }
        }
    }

    private func sessionCard(_ session: LibraryDatabase.MoveSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text(session.movedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.Text.quaternary)
                Text("\(session.logs.count) moves")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                stateChip(session.state)
                Spacer()
                if session.revertibleCount > 0 {
                    Button("Put all back") { revert(session) }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            ForEach(session.logs) { log in
                HStack(spacing: 8) {
                    Text(log.fileName)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(log.fromPath)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                    Text("→")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                    // A reverted row keeps its from → to with the
                    // destination struck through: the log is evidence
                    // that the move happened, not a description of where
                    // the file is now.
                    Text(log.toPath)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.Text.disabled)
                        .strikethrough(log.revertedAt != nil)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                    if log.revertedAt == nil {
                        Button("Put back") { revert(log) }
                            .buttonStyle(.plain)
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.Text.quaternary)
                            .frame(width: 92, alignment: .trailing)
                    } else {
                        Text("reverted")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .frame(width: 92, alignment: .trailing)
                    }
                }
                .opacity(log.revertedAt == nil ? 1 : 0.6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func stateChip(_ state: LibraryDatabase.MoveSession.State) -> some View {
        let color: Color = switch state {
        case .applied: Theme.Status.green
        case .partlyReverted: Theme.Status.orange
        case .fullyReverted: Theme.Text.disabled
        }
        return Text(state.displayName)
            .font(Theme.ui(9, .bold))
            .foregroundStyle(color)
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(color.opacity(0.15)))
    }

    // MARK: - Actions

    /// Bursty triggers (typing, listing refreshes, library changes) pass
    /// a settle so a burst makes one plan.
    private func preview(settle: Duration = .zero) {
        planner.preview(
            template: template, ids: scopeIDs,
            categoryNames: model.vocabulary.map(\.category.name), library: model.library,
            settle: settle)
    }

    private func apply() {
        guard !applying, let runner = try? app.runner(for: model.libraryID) else { return }
        applying = true
        // The plan on screen: its items and the template it was made
        // with, not what the field says by now.
        let ids = planner.plannedIDs
        let template = planner.plannedTemplate
        // Counted now: a newer plan can land before the queue answers.
        let count = planner.plan.movableCount
        Task {
            do {
                // Returns once queued: history and the plan refresh when
                // the moves land (the window follows the library's items).
                try await OrganiseMove.queue(on: runner, template: template, ids: ids)
                status = "\(count) moves queued — each one logged and revertible"
                // Move stays unavailable until the queue confirms the moves
                // (then "Moves queued…" takes over), so a second click
                // cannot land in between. Two seconds at most: a run that
                // finished that fast is never reported as pending at all.
                try? await Task.sleep(for: .seconds(2))
                applying = false
            } catch {
                applying = false
                errorText = "\(error)"
            }
        }
    }

    /// A file move, so off the main actor like putting back a whole run.
    private func revert(_ log: FileMoveLog) {
        let library = model.library, id = log.id
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try library.revertMove(id)
                    return nil
                } catch { return "\(error)" }
            }.value
            errorText = failure
            reloadHistory()
        }
    }

    /// Off the main actor: putting a run back is a file move per entry,
    /// and a run can be thousands.
    private func revert(_ session: LibraryDatabase.MoveSession) {
        let library = model.library
        status = "Putting \(session.revertibleCount) moves back…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try library.revertSession(session.id) }
            }.value
            finishRevert(result)
        }
    }

    private func finishRevert(_ result: Result<(reverted: Int, failures: [String]), any Error>) {
        do {
            let outcome = try result.get()
            errorText = outcome.failures.isEmpty
                ? nil : outcome.failures.joined(separator: "; ")
            status = "\(outcome.reverted) moves put back"
            reloadHistory()
        } catch { errorText = "\(error)" }
    }

    private func reloadHistory() {
        sessions = (try? model.library.moveSessions()) ?? []
    }
}

/// Re-plans when the listing's size changes. Its own view, so the listing
/// is read here and a refresh re-renders only this.
private struct ListingSizeWatch: View {
    let model: BrowseModel
    let changed: () -> Void

    var body: some View {
        Color.clear.onChange(of: model.visibleItems.count) { changed() }
    }
}

/// "applies to all N videos", following the listing without re-rendering
/// the window around it.
private struct WholeListingHeadline: View {
    let model: BrowseModel

    var body: some View {
        Text("applies to all \(model.visibleItems.count) videos in the library")
    }
}
