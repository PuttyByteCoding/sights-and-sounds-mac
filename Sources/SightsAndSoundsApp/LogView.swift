import SwiftUI
import SightsAndSoundsKit

/// The debug log: the in-memory ring buffer, live, with level/category
/// filters, search, and copy-out. Log lines can contain real file and
/// tag names — copied text is private data like any other.
///
/// A standalone window, so it is painted from the tokens like every
/// other content window: on a light system appearance it used to open
/// white beside the charcoal ones.
struct LogView: View {
    @State private var entries: [LogEntry] = []
    @State private var categories: [String] = []
    @State private var minimumLevel: LogLevel = .info
    @State private var category: String = "all"
    @State private var query = ""
    /// Whether the list is scrolled to its end. New lines are followed
    /// only then — jumping to the bottom while someone reads further up
    /// took the line they were reading away.
    @State private var atBottom = true

    private func filtered() -> [LogEntry] {
        entries.filter { entry in
            entry.level >= minimumLevel
                && (category == "all" || entry.category == category)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        // Filtered once per render: it was a property read three or four
        // times, each a substring search over the whole ring buffer.
        let shown = filtered()
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .frame(width: 140)
                .help("Minimum level to show")
                Picker("Category", selection: $category) {
                    Text("all").tag("all")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 170)
                TextField("", text: $query, prompt: Text("Search…"))
                    .themeField()
                Button("Copy All", systemImage: "doc.on.doc") { copyAll() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("Copy the filtered lines — treat the text as private data")
            }
            .padding(10)
            .background(Theme.Surface.toolbar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }

            if shown.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing logged yet")
                        .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                        .foregroundStyle(Theme.Text.secondary)
                    Text("Jobs, moves and errors appear here as they happen.")
                        .font(Theme.ui(Theme.TypeScale.body))
                        .foregroundStyle(Theme.Text.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(shown) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.Text.quaternary)
                            Text(entry.level.label)
                                .font(Theme.mono(11))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 52, alignment: .leading)
                            Text(entry.category)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.Text.tertiary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.message)
                                .font(Theme.ui(Theme.TypeScale.body))
                                .foregroundStyle(Theme.Text.primary)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.Surface.content)
                    }
                    .scrollContentBackground(.hidden)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 24
                    } action: { _, isAtBottom in
                        atBottom = isAtBottom
                    }
                    .onChange(of: shown.last?.id) {
                        if atBottom, let last = shown.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Theme.Surface.content)
        .frame(minWidth: 700, minHeight: 400)
        .task {
            while !Task.isCancelled {
                // Only when something was logged: assigning an equal
                // snapshot every second still re-rendered the whole list.
                let snapshot = AppLog.shared.snapshot()
                if snapshot.count != entries.count || snapshot.last?.id != entries.last?.id {
                    entries = snapshot
                    categories = AppLog.shared.categories()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: Theme.Text.quaternary
        case .info: Theme.Text.secondary
        case .warning: Theme.Status.orange
        case .error: Theme.Status.red
        }
    }

    private func copyAll() {
        let text = filtered().map { entry in
            "\(entry.date.formatted(date: .numeric, time: .standard)) [\(entry.level.label)] \(entry.category): \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
