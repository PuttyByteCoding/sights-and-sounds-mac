import SwiftUI
import SightsAndSoundsKit

/// The debug log: the in-memory ring buffer, live, with level/category
/// filters, search, and copy-out. Log lines can contain real file and
/// tag names — copied text is private data like any other.
struct LogView: View {
    @State private var entries: [LogEntry] = []
    @State private var categories: [String] = []
    @State private var minimumLevel: LogLevel = .info
    @State private var category: String = "all"
    @State private var query = ""

    private var filtered: [LogEntry] {
        entries.filter { entry in
            entry.level >= minimumLevel
                && (category == "all" || entry.category == category)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
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
                TextField("Search…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Copy All", systemImage: "doc.on.doc") { copyAll() }
                    .help("Copy the filtered lines — treat the text as private data")
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    "Nothing Logged Yet", systemImage: "text.alignleft",
                    description: Text("Jobs, moves and errors appear here as they happen."))
            } else {
                ScrollViewReader { proxy in
                    List(filtered) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(entry.level.label)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 52, alignment: .leading)
                            Text(entry.category)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(entry.message)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                    }
                    .onChange(of: filtered.last?.id) {
                        if let last = filtered.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .task {
            while !Task.isCancelled {
                entries = AppLog.shared.snapshot()
                categories = AppLog.shared.categories()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private func copyAll() {
        let text = filtered.map { entry in
            "\(entry.date.formatted(date: .numeric, time: .standard)) [\(entry.level.label)] \(entry.category): \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
