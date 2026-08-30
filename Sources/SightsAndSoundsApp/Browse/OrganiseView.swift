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
    @State private var validationErrors: [String] = []
    @State private var plan: [ReorganizePlanEntry] = []
    @State private var sessions: [LibraryDatabase.MoveSession] = []
    @State private var status: String?
    @State private var errorText: String?

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
    }

    private var header: some View {
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var headline: String {
        switch tab {
        case .plan:
            // Scope is the current filter, and it says so — rather than
            // leaving someone to discover that their filter was the
            // selection.
            "applies to the \(model.visibleItems.count) items in the current filter"
        case .history:
            "\(sessions.count) sessions · \(sessions.reduce(0) { $0 + $1.logs.count }) moves logged"
        }
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
                .onChange(of: template) { preview() }

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

            ForEach(validationErrors, id: \.self) { error in
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
                ForEach(plan, id: \.itemID) { entry in
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
                        stat("\(plan.movableCount)", "items would move")
                        stat("\(plan.count - plan.movableCount)", "skipped, left untouched")
                        stat("\(plan.foldersCreated.count)", "folders created")
                    }
                    if !plan.skipReasons.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Why items are skipped").modifier(Theme.sectionLabel())
                            ForEach(plan.skipReasons, id: \.reason) { entry in
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
                    if !plan.foldersCreated.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Folders this creates").modifier(Theme.sectionLabel())
                            ForEach(plan.foldersCreated, id: \.folder) { entry in
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
                Button(plan.movableCount == 0 ? "Nothing to move" : "Move \(plan.movableCount) items") {
                    apply()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(plan.movableCount == 0 || !validationErrors.isEmpty)
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

    private func preview() {
        validationErrors = OrganizeTemplate
            .validate(template, categoryNames: model.vocabulary.map(\.category.name))
            .map(\.message)
        guard validationErrors.isEmpty else {
            plan = []
            return
        }
        plan = (try? model.library.previewReorganize(
            template: template, itemIDs: model.visibleItems.map(\.id))) ?? []
    }

    private func apply() {
        guard let runner = try? app.runner(for: model.libraryID) else { return }
        let ids = model.visibleItems.map(\.id)
        let template = template
        Task {
            do {
                await runner.register(ReorganizeJob.self)
                _ = try await ReorganizeJob.enqueue(
                    on: runner, template: template, itemIDs: ids)
                try await runner.runPending()
                status = "\(plan.movableCount) moves queued — each one logged and revertible"
                reloadHistory()
                preview()
                model.refreshAll()
            } catch { errorText = "\(error)" }
        }
    }

    private func revert(_ log: FileMoveLog) {
        do {
            try model.library.revertMove(log.id)
            errorText = nil
            reloadHistory()
            model.refreshAll()
        } catch { errorText = "\(error)" }
    }

    private func revert(_ session: LibraryDatabase.MoveSession) {
        do {
            let outcome = try model.library.revertSession(session.id)
            errorText = outcome.failures.isEmpty
                ? nil : outcome.failures.joined(separator: "; ")
            status = "\(outcome.reverted) moves put back"
            reloadHistory()
            model.refreshAll()
        } catch { errorText = "\(error)" }
    }

    private func reloadHistory() {
        sessions = (try? model.library.moveSessions()) ?? []
    }
}
