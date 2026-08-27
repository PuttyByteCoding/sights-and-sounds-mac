import SwiftUI
import SightsAndSoundsKit

/// The indexed on-screen text for the current item — the OCR job's
/// timestamped lines, copyable, click-to-seek. The companion to Live
/// Text on the paused frame: this covers bulk extraction and text
/// between pauses; the overlay covers the exact frame the ~5 s sampling
/// may have missed.
struct OcrLinesPanel: View {
    @Environment(PlayerModel.self) private var model
    @Environment(AppModel.self) private var app
    var width: CGFloat = 300

    @State private var lines: [OcrTextLine] = []
    @State private var scanQueued = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("On-Screen Text").font(.headline)
                Spacer()
                if !lines.isEmpty {
                    Button("Copy All", systemImage: "doc.on.doc") { copyAll() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Copy every line with its timestamp")
                }
            }
            .padding(10)
            Divider()
            if lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(scanQueued
                        ? "Scan queued — reopen this panel when it finishes."
                        : "No scanned text for this item yet.")
                        .foregroundStyle(.secondary)
                    if !scanQueued {
                        Button("Scan On-Screen Text", systemImage: "text.viewfinder") {
                            enqueueScan()
                        }
                    }
                }
                .font(.callout)
                .padding(10)
                Spacer()
            } else {
                List(lines) { line in
                    Button {
                        model.seek(to: line.timeSeconds)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(TransportBarTime.format(line.timeSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tint)
                            Text(line.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Seek to \(TransportBarTime.format(line.timeSeconds))")
                }
            }
        }
        .frame(width: width)
        .background(.background.secondary)
        .task(id: model.item?.id) { await reload() }
    }

    private func reload() async {
        guard let itemID = model.item?.id else {
            lines = []
            return
        }
        scanQueued = false
        let library = model.library
        // Explicit return type — the async `read` overload's inference
        // is ambiguous to the CI toolchain (Xcode 16).
        let fetched: [OcrTextLine] = (try? await library.writer.read { db -> [OcrTextLine] in
            try OcrTextLine
                .filter(sql: "mediaItemID = ?", arguments: [itemID])
                .order(sql: "timeSeconds")
                .fetchAll(db)
        }) ?? []
        lines = fetched
    }

    private func enqueueScan() {
        guard let itemID = model.item?.id,
              let runner = try? app.runner(for: model.libraryID)
        else { return }
        scanQueued = true
        Task {
            _ = try? await OcrJob.enqueue(on: runner, itemID: itemID)
            _ = try? await runner.runPending()
            await reload()
        }
    }

    private func copyAll() {
        let text = lines
            .map { "\(TransportBarTime.format($0.timeSeconds))\t\($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
