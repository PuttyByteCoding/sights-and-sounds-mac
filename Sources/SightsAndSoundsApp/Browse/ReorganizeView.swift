import SwiftUI
import SightsAndSoundsKit

/// Template reorganization: type a template, see exactly what would move
/// and what would be skipped and why, then apply — every move logged and
/// revertible from Move History.
struct ReorganizeView: View {
    @Environment(BrowseModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var template = "%Band/%Year"
    @State private var validationErrors: [String] = []
    @State private var plan: [ReorganizePlanEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reorganize by Template").font(.title3)
            Text("Tokens name your categories (%Band, %Year — underscores for spaces). Applies to the current filtered items; every move is revertible from Move History.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Template", text: $template)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { preview() }
                Button("Preview") { preview() }
            }

            ForEach(validationErrors, id: \.self) { error in
                Text(error).foregroundStyle(.red).font(.callout)
            }

            if !plan.isEmpty {
                List(plan, id: \.itemID) { entry in
                    HStack {
                        Text(entry.fileName).lineLimit(1)
                        Spacer()
                        if let to = entry.toFolder {
                            Text("\(entry.fromFolder) → \(to)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(entry.reason ?? "skipped")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(minHeight: 220)
                let movable = plan.filter { $0.toFolder != nil }.count
                Text("\(movable) of \(plan.count) items would move.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                let movable = plan.filter { $0.toFolder != nil }
                Button("Move \(movable.count) Items") {
                    model.reorganize(template: template, itemIDs: movable.map(\.itemID))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(movable.isEmpty || !validationErrors.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func preview() {
        let categoryNames = model.vocabulary.map(\.category.name)
        validationErrors = OrganizeTemplate.validate(template, categoryNames: categoryNames)
            .map(\.message)
        guard validationErrors.isEmpty else {
            plan = []
            return
        }
        plan = (try? model.library.previewReorganize(
            template: template, itemIDs: model.items.map(\.id))) ?? []
    }
}
