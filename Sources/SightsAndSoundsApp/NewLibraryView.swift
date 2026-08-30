import SwiftUI
import SightsAndSoundsKit

/// Making a library, in four steps — **Name · Vocabulary · Review ·
/// Source**.
///
/// The plan model has always been far richer than the screen: it carries
/// how many values a category takes, how it displays, how names are
/// normalized, what it writes into files, its tags with their aliases,
/// and its tag fields. None of that was editable at creation, so a new
/// library was created and then immediately reconfigured somewhere else.
/// The review step edits the whole plan.
///
/// **Nothing is written until the last step.**
struct NewLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case name, vocabulary, review, source

        var title: String {
            switch self {
            case .name: "Name"
            case .vocabulary: "Vocabulary"
            case .review: "Review"
            case .source: "Source"
            }
        }

        var subtitle: String {
            switch self {
            case .name: "what it is called, and where it lives"
            case .vocabulary: "a starting point, not a commitment"
            case .review: "rename, reconfigure, reorder, exclude"
            case .source: "a folder to watch — skippable"
            }
        }
    }

    @State private var step: Step = .name
    @State private var libraryName = ""
    @State private var template: LibraryTemplate = .concerts
    @State private var plan = LibraryTemplate.concerts.plan(named: "Concerts")
    @State private var sourceURL: URL?
    @State private var creationError: String?
    @State private var verification: CreationVerification?

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Rectangle().fill(Theme.Border.standard).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        content
                    }
                    .padding(16)
                }
                footer
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.Surface.content)
    }

    // MARK: - Step rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Library").modifier(Theme.sectionLabel())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            ForEach(Step.allCases, id: \.self) { entry in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(entry.rawValue + 1)")
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(numberColor(entry))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(numberFill(entry)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(Theme.ui(12.5, entry == step ? .semibold : .regular))
                            .foregroundStyle(
                                entry == step ? Theme.Text.primary : Theme.Text.tertiary)
                        Text(entry.subtitle)
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.Text.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(entry == step ? Theme.Surface.selectedRow : .clear)
            }
            Spacer()
            // What the plan currently amounts to, updating as it is
            // edited — the thing you are about to commit to.
            VStack(alignment: .leading, spacing: 4) {
                Text("Will create").modifier(Theme.sectionLabel())
                summaryRow("categories", included.count)
                summaryRow("tags", included.reduce(0) { $0 + $1.tags.count })
                summaryRow(
                    "field definitions",
                    included.reduce(0) { $0 + $1.fields.count }
                        + plan.itemFields.filter(\.include).count)
            }
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Border.standard).frame(height: 1)
            }
        }
        .frame(width: 250)
        .background(Theme.Surface.sidebar)
    }

    private func summaryRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            Spacer()
            Text("\(value)")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    private func numberColor(_ entry: Step) -> Color {
        if entry.rawValue < step.rawValue { return Theme.Status.greenBright }
        return entry == step ? Theme.Text.onAmber : Theme.Text.disabled
    }

    private func numberFill(_ entry: Step) -> Color {
        if entry.rawValue < step.rawValue { return Theme.Status.goodBadgeFill }
        return entry == step ? Theme.Accent.amber : Theme.Surface.iconTile
    }

    // MARK: - Header and content

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.ui(Theme.TypeScale.windowHeading, .semibold))
                .foregroundStyle(Theme.Text.primary)
            Text(blurb)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .name: "Name the library"
        case .vocabulary: "Choose a starting vocabulary"
        case .review: "Review the vocabulary"
        case .source: "Add a source"
        }
    }

    private var blurb: String {
        switch step {
        case .name:
            "Each library is one file with its own categories, tags and sources. Cross-library leakage is structurally impossible rather than merely forbidden."
        case .vocabulary:
            "A template only seeds the review screen. Everything it proposes can be renamed, reconfigured or dropped before anything is written."
        case .review:
            "Rename, reconfigure, reorder or exclude anything here. This is the same screen migration uses, so a library made either way is configured the same way."
        case .source:
            "A source is a folder this library watches. You can skip this and add one later."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .name: nameStep
        case .vocabulary: vocabularyStep
        case .review: reviewStep
        case .source: sourceStep
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Library name", text: $libraryName, prompt: Text(template.displayName))
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.well)
                        .stroke(Theme.Border.standard, lineWidth: 1))
            // Decided Aug 2026: a library file is a plainly-named SQLite
            // database, openable by any SQLite tool without explaining an
            // extension to it first.
            Text("\(effectiveName).sqlite")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.Accent.amber)
            Text("You choose where it goes when you create it.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
        }
    }

    private var vocabularyStep: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(LibraryTemplate.allCases) { entry in
                let picked = template == entry
                Button {
                    template = entry
                    plan = entry.plan(named: effectiveName)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.categoryHue(entry.hashValue))
                                .frame(width: 7, height: 7)
                            Text(entry.displayName)
                                .font(Theme.ui(12.5, .semibold))
                                .foregroundStyle(Theme.Text.primary)
                            Spacer(minLength: 0)
                            Text("\(entry.plan(named: "x").categories.count) categories")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.Text.disabled)
                        }
                        // One string, one place.
                        Text(entry.summary)
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        FlowRow(spacing: 4) {
                            ForEach(
                                entry.plan(named: "x").categories.prefix(4).map(\.name),
                                id: \.self
                            ) { name in
                                Text(name)
                                    .font(Theme.ui(10))
                                    .foregroundStyle(Theme.Text.quaternary)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 7)
                                    .background(Capsule().fill(Theme.Surface.iconTile))
                            }
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .fill(picked ? Theme.Surface.selectedRow : Theme.Surface.raised)
                            .stroke(
                                picked ? Theme.Accent.amber : Theme.Border.standard, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Dragging to reorder IS setting the focus now: focus is the
            // first visible category, which is one fewer setting and one
            // fewer unrepresentable conflict.
            Text("Categories appear in the tag editor in this order — the first one takes the cursor.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
            ForEach($plan.categories) { $category in
                CategoryPlanCard(
                    category: $category,
                    onMoveUp: { move(category.id, by: -1) },
                    onMoveDown: { move(category.id, by: 1) })
            }
            if !plan.itemFields.isEmpty {
                Text("Media item fields").modifier(Theme.sectionLabel())
                ForEach($plan.itemFields) { $field in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $field.include).labelsHidden()
                        TextField("Name", text: $field.name)
                            .textFieldStyle(.plain)
                            .font(Theme.ui(12))
                        Picker("", selection: $field.dataType) {
                            ForEach(FieldDataType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.Surface.raised))
                }
            }
        }
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Status.green).frame(width: 7, height: 7)
                    PathText(path: sourceURL.path, size: 11, color: Theme.Text.secondary)
                    Spacer()
                    Button("Remove") { self.sourceURL = nil }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(Theme.Surface.raised))
            }
            Button("+ Add a source folder…") { chooseSource() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Text("Adding a source registers the folder and runs a scan. Nothing enters the library until you confirm the import, so you can add these later without committing to anything.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.Text.disabled)
                .fixedSize(horizontal: false, vertical: true)
            if let verification {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Created").modifier(Theme.sectionLabel())
                    verificationRow("categories", verification.categories, expected.categories)
                    verificationRow("tags", verification.tags, expected.tags)
                    verificationRow("aliases", verification.aliases, expected.aliases)
                    verificationRow("field definitions", verification.fields, expected.fields)
                }
            }
        }
    }

    private func verificationRow(_ label: String, _ actual: Int, _ wanted: Int) -> some View {
        HStack {
            Text(label)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Text.tertiary)
            Spacer()
            Text("\(actual) of \(wanted)")
                .font(Theme.mono(11))
                .foregroundStyle(actual == wanted ? Theme.Status.green : Theme.Status.red)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = validationError ?? creationError {
                HStack(spacing: 6) {
                    Circle().fill(Theme.Status.red).frame(width: 5, height: 5)
                    Text(error)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.Status.redBright)
                        .lineLimit(2)
                }
            } else {
                Text(hint)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.Text.disabled)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            if step != .name {
                Button("Back") { back() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            Button(step == .source ? "Create library" : "Continue") { advance() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(step == .source && validationError != nil)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Theme.Surface.toolbar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Border.standard).frame(height: 1)
        }
    }

    private var hint: String {
        switch step {
        case .name, .vocabulary, .review: "Nothing is written until the last step."
        case .source: "You can add sources later."
        }
    }

    /// Continuous, and shown at the button — not collected into a dialog
    /// that appears after Create is pressed.
    private var validationError: String? {
        plan.validationErrors().first
    }

    // MARK: - Derived

    private var effectiveName: String {
        libraryName.trimmingCharacters(in: .whitespaces).isEmpty
            ? template.displayName
            : libraryName.trimmingCharacters(in: .whitespaces)
    }

    private var included: [PlannedCategory] { plan.categories.filter(\.include) }

    private var expected: CreationVerification { .expected(from: plan) }

    // MARK: - Actions

    private func advance() {
        switch step {
        case .name:
            plan = template.plan(named: effectiveName)
            step = .vocabulary
        case .vocabulary:
            plan.name = effectiveName
            step = .review
        case .review:
            step = .source
        case .source:
            create()
        }
    }

    private func back() {
        step = Step(rawValue: max(0, step.rawValue - 1)) ?? .name
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let index = plan.categories.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard plan.categories.indices.contains(target) else { return }
        plan.categories.swapAt(index, target)
        // sortOrder is the order, so the order has to be written down.
        for (position, _) in plan.categories.enumerated() {
            plan.categories[position].sortOrder = position * 10
        }
    }

    /// The folder picker is the system's — a browser could not open one,
    /// which is why the comp draws its own.
    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose a source folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Source"
        guard panel.runModal() == .OK else { return }
        sourceURL = panel.url
    }

    private func create() {
        let panel = NSSavePanel()
        panel.title = "Create Library"
        panel.nameFieldStringValue = plan.name + ".sqlite"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = sourceURL.map {
                Source(name: $0.lastPathComponent, rootPath: $0.path)
            }
            let library = try LibraryCreator.create(
                at: url, plan: plan, firstSource: source, registerIn: model.appDatabase)
            // Read the library back and compare. A mismatch is cheaper to
            // know now than after a week of tagging.
            verification = try library.creationVerification()
            model.refresh()
            if verification?.matches(expected) ?? false {
                dismiss()
            } else {
                creationError = "Created, but the counts do not match the plan — see below."
            }
        } catch {
            creationError = "\(error)"
        }
    }
}

/// One category, with the plan's real fields rather than a poorer set.
/// This is the same vocabulary Categories & Fields edits later.
private struct CategoryPlanCard: View {
    @Binding var category: PlannedCategory
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up").font(Theme.ui(9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Text.disabled)
                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down").font(Theme.ui(9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Text.disabled)
                // Excluding is not deleting: an unchecked category is
                // never created, rather than written and then removed.
                Toggle("", isOn: $category.include)
                    .labelsHidden()
                    .help("Unchecked categories are never created — their tags and fields simply never exist")
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.categoryHue(category.colorIndex))
                    .frame(width: 6, height: 6)
                TextField("Name", text: $category.name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .disabled(!category.include)
                if category.name != category.originalName {
                    Text("was \(category.originalName)")
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.Text.disabled)
                }
                Spacer(minLength: 0)
                Text(summary)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.Text.disabled)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(Theme.ui(9))
                        .foregroundStyle(Theme.Text.disabled)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
            }
            if expanded, category.include {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Allow multiple per item", isOn: $category.allowMultiple)
                        .toggleStyle(.checkbox)
                    Picker("Display style", selection: $category.displayStyle) {
                        ForEach(TagDisplayStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Toggle("Hidden from browse filters", isOn: $category.hiddenFromBrowse)
                        .toggleStyle(.checkbox)
                    Picker("Name formatting", selection: $category.textFormat) {
                        Text("As typed").tag(TextFormat.noFormatting)
                        Text("Title Case").tag(TextFormat.titleCase)
                        Text("lowercase").tag(TextFormat.allLowercase)
                        Text("UPPERCASE").tag(TextFormat.allUppercase)
                    }
                    Toggle("Separators to spaces", isOn: $category.separatorsToSpaces)
                        .toggleStyle(.checkbox)
                    Toggle("Write tags into files", isOn: $category.writebackEnabled)
                        .toggleStyle(.checkbox)
                    Picker("Write-back field", selection: $category.writebackField) {
                        Text("Auto (custom field)").tag(String?.none)
                        ForEach(StandardFields.all, id: \.key) { field in
                            Text(field.key).tag(String?.some(field.key))
                        }
                    }
                    .disabled(!category.writebackEnabled)
                    if !category.tags.isEmpty {
                        Text("Tags").modifier(Theme.sectionLabel())
                        FlowRow(spacing: 4) {
                            ForEach(Array(category.tags.enumerated()), id: \.offset) { _, tag in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tag.name)
                                        .font(Theme.ui(11))
                                        .foregroundStyle(Theme.Text.secondary)
                                    if !tag.aliases.isEmpty {
                                        Text(tag.aliases.joined(separator: ", "))
                                            .font(Theme.mono(9))
                                            .foregroundStyle(Theme.Text.disabled)
                                    }
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                        .fill(Theme.Surface.iconTile))
                            }
                        }
                    }
                    if !category.fields.isEmpty {
                        Text("Tag fields").modifier(Theme.sectionLabel())
                        ForEach(Array(category.fields.enumerated()), id: \.offset) { _, field in
                            Text("\(field.name) · \(field.dataType.rawValue)")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.Text.quaternary)
                        }
                    }
                }
                .font(Theme.ui(12))
                .foregroundStyle(Theme.Text.secondary)
                .padding(.leading, 22)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Surface.raised)
                .stroke(Theme.Border.standard, lineWidth: 1))
        .opacity(category.include ? 1 : 0.55)
    }

    /// The collapsed summary already read well; kept.
    private var summary: String {
        var parts: [String] = [category.allowMultiple ? "multiple" : "single"]
        if category.displayStyle != .search {
            parts.append(category.displayStyle.displayName.lowercased())
        }
        if !category.tags.isEmpty { parts.append("\(category.tags.count) tags") }
        if let field = category.writebackField { parts.append("→ \(field)") }
        return parts.joined(separator: " · ")
    }
}
