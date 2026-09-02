import SwiftUI
import SightsAndSoundsKit

/// The inspector: raw in and processed out, per reader, for the
/// displayed video. The left of each section is EXACTLY what the reader
/// handed the pipeline; the right is every candidate whose origins name
/// that reader — so "the reader saw it but nothing came out" and "the
/// reader never saw it" stop looking identical.
struct ReaderIOSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: TagAnalysisModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.analysis.readerReports) { report in
                        section(report)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 560)
        .background(Theme.Surface.dialog)
        .onKeyPress { press in
            if press.key == .escape {
                dismiss()
                return .handled
            }
            return .ignored
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Reader I/O").modifier(Theme.sectionLabel(Theme.Accent.amber))
            Text(model.currentItem?.fileName ?? "—")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.Text.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private func section(_ report: ReaderReport) -> some View {
        let produced = model.candidates(fromReader: report.readerID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(report.displayName).modifier(Theme.sectionLabel())
                Text("\(report.sources.count) in · \(produced.count) out")
                    .font(Theme.mono(10))
                    .foregroundStyle(
                        report.sources.isEmpty ? Theme.Text.zeroCount : Theme.Text.quaternary)
                Spacer()
            }

            if let error = report.error {
                // The whole reason the error is stored: a reader that
                // threw must not look like a reader that found nothing.
                Text("Reader failed: \(error)")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Status.red)
            } else if report.sources.isEmpty {
                Text("Nothing found.")
                    .font(Theme.ui(Theme.TypeScale.secondary))
                    .foregroundStyle(Theme.Text.disabled)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    column("Raw in") {
                        ForEach(Array(report.sources.enumerated()), id: \.offset) { _, source in
                            rawRow(source)
                        }
                    }
                    column("Processed out") {
                        if produced.isEmpty {
                            Text("Nothing survived — parsed away, rule-ignored, or already a tag.")
                                .font(Theme.ui(10.5))
                                .foregroundStyle(Theme.Text.disabled)
                        }
                        ForEach(produced) { row in
                            producedRow(row)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
    }

    private func column<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.ui(10, .bold))
                .foregroundStyle(Theme.Text.quaternary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rawRow(_ source: AnalysisSourceText) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if let key = source.key {
                    Text(key)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Status.blueBright)
                }
                if let file = source.sourceFile {
                    Text(file)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Status.orangeMuted)
                }
                if let seconds = source.timeSeconds {
                    Text(TransportBarTime.format(seconds))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.Text.quaternary)
                }
            }
            Text(source.text)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.Text.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.Surface.well))
    }

    private func producedRow(_ row: TagAnalysisModel.TableRow) -> some View {
        HStack(spacing: 6) {
            Text(row.candidate.value)
                .font(Theme.ui(11))
                .foregroundStyle(
                    row.candidate.suppressedByRule == nil
                        ? Theme.Text.primary : Theme.Text.disabled)
                .strikethrough(row.candidate.suppressedByRule != nil)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(bucketLabel(row))
                .font(Theme.ui(9))
                .foregroundStyle(bucketColor(row))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.Surface.well))
    }

    private func bucketLabel(_ row: TagAnalysisModel.TableRow) -> String {
        if row.candidate.suppressedByRule != nil { return "ignored" }
        if row.candidate.category != nil { return "suggested" }
        if !row.findings.isEmpty { return "existing" }
        return "unmapped"
    }

    private func bucketColor(_ row: TagAnalysisModel.TableRow) -> Color {
        if row.candidate.suppressedByRule != nil { return Theme.Status.orange }
        if row.candidate.category != nil { return Theme.Status.greenBright }
        if !row.findings.isEmpty { return Theme.Status.blueBright }
        return Theme.Text.quaternary
    }
}
