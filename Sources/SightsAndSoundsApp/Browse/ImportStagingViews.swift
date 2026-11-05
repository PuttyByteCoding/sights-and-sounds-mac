import SwiftUI
import SightsAndSoundsKit

/// One media-item field box under the Import window's tag panel. Tags
/// are staged in the panel itself, the player's own; a box is a field's
/// value, and whether it stays for the next import.
struct StagingBoxView: View {
    let box: ImportBox
    let fields: [FieldDefinition]
    @Binding var draft: StagingDraft
    let onSticky: (Bool) -> Void

    var body: some View {
        if let definition {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(definition.name)
                        .font(Theme.ui(12, .semibold))
                        .foregroundStyle(Theme.Text.primary)
                    Spacer(minLength: 0)
                    StickyChip(on: box.sticky) { onSticky(!box.sticky) }
                }
                TextField("Value", text: Binding(
                    get: { draft.fieldValues[definition.id] ?? "" },
                    set: { draft.fieldValues[definition.id] = $0.isEmpty ? nil : $0 })
                )
                .textFieldStyle(.plain)
                .font(Theme.ui(12))
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            }
        }
    }

    private var definition: FieldDefinition? {
        guard let id = box.fieldID else { return nil }
        return fields.first { $0.id == id }
    }
}

/// Which media-item fields the stage rail offers, and in what order.
/// Every tag category is in the panel above them already; a category's
/// box survives only as the record of whether it is sticky.
struct ConfigureBoxesSheet: View {
    @Binding var boxes: [ImportBox]
    let fields: [FieldDefinition]
    let onSave: ([ImportBox]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Configure field boxes")
                    .font(Theme.ui(Theme.TypeScale.dialogTitle, .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Check the media-item fields to stage under the tag panel. Values staged there apply to every file in the import.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if fields.isEmpty {
                        Text("This library has no media-item fields. Add them in the Categories window.")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.Text.meta)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Media item fields").modifier(Theme.sectionLabel())
                            .padding(.bottom, 4)
                        ForEach(fields) { field in
                            row(
                                label: field.name,
                                hue: Theme.Text.quaternary,
                                isOn: boxes.contains { $0.fieldID == field.id },
                                toggle: { toggleField(field.id) })
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 320)

            HStack {
                Spacer()
                Button("Done") {
                    onSave(boxes)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(Theme.Surface.dialog)
    }

    private func row(
        label: String, hue: Color, isOn: Bool, toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isOn ? Theme.Accent.amber : .clear)
                    .stroke(
                        isOn ? Theme.Accent.amber : Theme.Border.subtleButtonHover, lineWidth: 1)
                    .frame(width: 13, height: 13)
                RoundedRectangle(cornerRadius: 2).fill(hue).frame(width: 6, height: 6)
                Text(label)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.Text.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleField(_ id: UUID) {
        if let index = boxes.firstIndex(where: { $0.fieldID == id }) {
            boxes.remove(at: index)
        } else {
            boxes.append(ImportBox(source: .itemField(id)))
        }
    }
}
