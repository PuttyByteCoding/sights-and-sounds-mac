import SwiftUI
import SightsAndSoundsKit

/// Early app shell: the library registry and the new-library flow (name →
/// template → review → create). The browse workspace arrives in Phase 3.
@main
struct SightsAndSoundsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryListView()
                .environment(model)
        }
    }
}

/// App-level state: the registry store, opened once.
@Observable @MainActor
final class AppModel {
    let appDatabase: AppDatabase?
    var libraries: [LibraryRef] = []
    var loadError: String?

    init() {
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("SightsAndSounds", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            appDatabase = try AppDatabase.open(at: dir.appendingPathComponent("App.sqlite"))
        } catch {
            appDatabase = nil
            loadError = "Could not open the app store: \(error)"
        }
        refresh()
    }

    func refresh() {
        guard let appDatabase else { return }
        do { libraries = try appDatabase.libraries() } catch {
            loadError = "Could not read libraries: \(error)"
        }
    }
}

struct LibraryListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).padding()
            }
            if model.libraries.isEmpty {
                ContentUnavailableView(
                    "No Libraries",
                    systemImage: "books.vertical",
                    description: Text("Create your first library to get started."))
            } else {
                List(model.libraries) { library in
                    VStack(alignment: .leading) {
                        Text(library.name).font(.headline)
                        Text(library.filePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle("Sights and Sounds")
        .toolbar {
            Button("New Library…", systemImage: "plus") { showingNewLibrary = true }
        }
        .sheet(isPresented: $showingNewLibrary) {
            NewLibraryFlow()
                .environment(model)
        }
    }
}

/// Name + template → category review → create. The review step edits a
/// `LibraryPlan`; nothing exists on disk until Create.
struct NewLibraryFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var libraryName = ""
    @State private var template: LibraryTemplate = .concerts
    @State private var plan: LibraryPlan?
    @State private var creationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let planBinding = Binding($plan) {
                reviewStep(planBinding)
            } else {
                setupStep
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
    }

    private var setupStep: some View {
        Form {
            TextField("Library name", text: $libraryName, prompt: Text("Concerts"))
            Picker("Template", selection: $template) {
                ForEach(LibraryTemplate.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            Text(template.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Review Categories") {
                    let name = libraryName.isEmpty ? template.displayName : libraryName
                    plan = template.plan(named: name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func reviewStep(_ plan: Binding<LibraryPlan>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review — \(plan.wrappedValue.name)")
                .font(.title2)
            Text("Rename or exclude anything. Nothing is written until Create.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                Section("Categories") {
                    ForEach(plan.categories) { $category in
                        HStack {
                            Toggle("", isOn: $category.include).labelsHidden()
                            TextField("Name", text: $category.name)
                                .disabled(!category.include)
                            Spacer()
                            Text(categorySummary(category))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.wrappedValue.itemFields.isEmpty {
                    Section("Fields") {
                        ForEach(plan.itemFields) { $field in
                            HStack {
                                Toggle("", isOn: $field.include).labelsHidden()
                                TextField("Name", text: $field.name)
                                    .disabled(!field.include)
                                Spacer()
                                Text(field.dataType.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let creationError {
                Text(creationError).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Back") { self.plan = nil }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create(plan.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func categorySummary(_ category: PlannedCategory) -> String {
        var parts: [String] = [category.allowMultiple ? "multiple" : "single"]
        if category.displayAsCheckboxes { parts.append("checkboxes") }
        if !category.tags.isEmpty { parts.append("\(category.tags.count) tags") }
        if let field = category.writebackField { parts.append("→ \(field)") }
        return parts.joined(separator: " · ")
    }

    private func create(_ plan: LibraryPlan) {
        let panel = NSSavePanel()
        panel.title = "Create Library"
        panel.nameFieldStringValue = plan.name + ".sqlite"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryCreator.create(at: url, plan: plan, registerIn: model.appDatabase)
            model.refresh()
            dismiss()
        } catch {
            creationError = "\(error)"
        }
    }
}
