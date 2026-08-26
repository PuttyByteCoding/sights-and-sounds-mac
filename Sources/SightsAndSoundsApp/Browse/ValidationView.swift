import SwiftUI
import SightsAndSoundsKit

/// The latest validation sweep's findings, with one honest action each.
struct ValidationView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var findings: [ValidationFinding] = []
    @State private var running = false
    @State private var statusText: String?

    var body: some View {
        VStack(spacing: 0) {
            if findings.isEmpty && !running {
                ContentUnavailableView(
                    "No Findings", systemImage: "checkmark.seal",
                    description: Text("Run a sweep to compare the library against the disk."))
            } else {
                List(findings) { finding in
                    HStack {
                        icon(for: finding.kind)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(finding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        actionButton(for: finding)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Button(running ? "Sweeping…" : "Run Sweep", systemImage: "magnifyingglass") { runSweep() }
                    .disabled(running)
                if let statusText {
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { reload() }
    }

    @ViewBuilder private func icon(for kind: ValidationFindingKind) -> some View {
        switch kind {
        case .missingFile: Image(systemName: "questionmark.folder").foregroundStyle(.red)
        case .orphanFile: Image(systemName: "doc.badge.plus").foregroundStyle(.blue)
        case .sizeMismatch: Image(systemName: "arrow.left.arrow.right").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func actionButton(for finding: ValidationFinding) -> some View {
        switch finding.kind {
        case .missingFile:
            if let itemID = finding.mediaItemID {
                Button("Mark for Deletion") {
                    try? model.library.stage(.toDelete, itemID: itemID)  // file gone → flag-only
                    reload()
                    model.refreshAll()
                }
                .controlSize(.small)
            }
        case .orphanFile:
            Button("Import Now") {
                if let source = model.sources.first { model.importSource(source) }
                dismiss()
            }
            .controlSize(.small)
        case .sizeMismatch:
            if let itemID = finding.mediaItemID {
                Button("Accept Disk Size") {
                    try? model.library.acceptDiskSize(for: itemID)
                    reload()
                }
                .controlSize(.small)
            }
        }
    }

    private func reload() {
        findings = (try? model.library.validationFindings()) ?? []
    }

    private func runSweep() {
        running = true
        statusText = nil
        Task {
            await model.runValidation()
            running = false
            reload()
            statusText = "\(findings.count) findings"
        }
    }
}
