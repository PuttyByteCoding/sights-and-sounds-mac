import SwiftUI
import SightsAndSoundsKit

/// The indexed on-screen text for the current item — the OCR job's
/// timestamped lines, copyable, click-to-seek.
///
/// It is a **drawer under the transport**, not a second side panel. The
/// lines are short and timestamped: they read better wide than tall, and
/// as a side panel they competed with the tag panel for width, which is
/// what forced two panels to scale jointly against the video floor.
///
/// Every action here is scoped to the playing item — copy a line, make it
/// a tag on this item, make it an alias of a tag. Anything plural ("every
/// item whose text says this") is a link into Tag Analysis, never an
/// action here; that one rule is what stops OCR from becoming two
/// implementations of one feature in two windows.
struct OcrLinesPanel: View {
    @Environment(PlayerModel.self) private var model
    @Environment(AppModel.self) private var app
    var height: CGFloat = 112

    @State private var lines: [OcrTextLine] = []
    @State private var scanQueued = false
    @State private var tagSheetLine: OcrTextLine?
    @State private var aliasSheetLine: OcrTextLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if lines.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(lines) { line in
                            LineRow(
                                line: line,
                                onTag: { tagSheetLine = line },
                                onAlias: { aliasSheetLine = line })
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.raised)
        .task(id: model.item?.id) { await reload() }
        .sheet(item: $tagSheetLine) { line in
            OcrTagSheet(line: line, mode: .tag).environment(model)
        }
        .sheet(item: $aliasSheetLine) { line in
            OcrTagSheet(line: line, mode: .alias).environment(model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("On-screen text").modifier(Theme.sectionLabel())
            Text("Vision OCR · click a line to seek")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            if !lines.isEmpty {
                Button("Copy all") { copyAll() }
                    .buttonStyle(.plain)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Text.quaternary)
                    .help("Copy every line with its timestamp")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Text(scanQueued
                ? "Scan queued — reopen this panel when it finishes."
                : "No scanned text for this item yet.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.disabled)
            if !scanQueued {
                Button("Scan On-Screen Text") { enqueueScan() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            Spacer()
        }
        .padding(12)
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

private struct LineRow: View {
    @Environment(PlayerModel.self) private var model
    let line: OcrTextLine
    let onTag: () -> Void
    let onAlias: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TransportBarTime.format(line.timeSeconds))
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Accent.amber)
            Text(line.text)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 0)
            // The actions appear on hover so a hundred lines read as
            // text rather than as a hundred toolbars.
            if hovering {
                action("Copy") { copy() }
                action("+ Tag", onTag)
                action("+ Alias", onAlias)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(hovering ? Theme.Surface.selectedRow : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.seek(to: line.timeSeconds) }
        .onHover { hovering = $0 }
        .help("Seek to \(TransportBarTime.format(line.timeSeconds))")
    }

    private func action(_ label: String, _ perform: @escaping () -> Void) -> some View {
        Button(label, action: perform)
            .buttonStyle(.plain)
            .font(Theme.ui(10.5))
            .foregroundStyle(Theme.Text.quaternary)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.text, forType: .string)
    }
}

/// Turning one recognized line into vocabulary — as a tag on this item,
/// or as an alias of a tag that already exists.
private struct OcrTagSheet: View {
    enum Mode { case tag, alias }

    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let line: OcrTextLine
    let mode: Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            picker
            footer
        }
        .frame(width: 440)
        .background(Theme.Surface.dialog)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .tag ? "Make this a tag" : "Make this an alias")
                .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(line.text)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.Accent.amber)
                .padding(.vertical, 6)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            Text(mode == .tag
                ? "Creates the tag in the chosen category and applies it to this item only. The category's formatting rule normalizes the name."
                : "The line becomes an alternative name for the tag you pick, so future searches and imports resolve it.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    /// The choices, flattened before the view builder sees them — a
    /// nested ForEach over categories and their tags is what makes the
    /// type checker give up on this body.
    private struct Choice: Identifiable {
        var id: UUID
        var label: String
        var hue: Color
        var hint: String
        var apply: () -> Void
    }

    private var choices: [Choice] {
        model.panelVocabulary.flatMap { entry -> [Choice] in
            let hue = Theme.categoryHue(entry.category.colorIndex)
            switch mode {
            case .tag:
                return [Choice(
                    id: entry.category.id, label: entry.category.name, hue: hue,
                    hint: "\(entry.tags.count) tags",
                    apply: { model.addTag(named: line.text, categoryID: entry.category.id) })]
            case .alias:
                return entry.tags.map { tag in
                    Choice(
                        id: tag.id, label: tag.name, hue: hue, hint: entry.category.name,
                        apply: { model.addAlias(line.text, to: tag.id) })
                }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode == .tag ? "Category" : "Tag")
                .modifier(Theme.sectionLabel())
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(choices) { choice in
                        pickRow(choice)
                    }
                }
            }
            .frame(maxHeight: 186)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            // Plural questions belong to Tag Analysis, which is the
            // window that can answer them — never to a second
            // implementation living here.
            Button("Find across the library →") {}
                .buttonStyle(.plain)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.disabled)
                .disabled(true)
                .help("Arrives with the Tag Analysis window")
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func pickRow(_ choice: Choice) -> some View {
        Button {
            choice.apply()
            dismiss()
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(choice.hue)
                    .frame(width: 6, height: 6)
                Text(choice.label)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.secondary)
                Spacer(minLength: 0)
                Text(choice.hint)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
