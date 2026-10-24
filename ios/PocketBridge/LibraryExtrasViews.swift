import SwiftUI

/// Paired Pocket status at the top of Recordings: battery, storage, new recordings and a live transcript.
struct PocketStatusCard: View {
    @Environment(PocketDeviceController.self) private var pocket
    let name: String
    var openPocket: () -> Void

    private var detail: String {
        guard pocket.authenticated else { return pocket.status }
        var parts: [String] = []
        if let battery = pocket.battery { parts.append("\(battery)%") }
        if let free = pocket.storageFreeMB { parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(free) * 1_000_000, countStyle: .file)) free") }
        if pocket.busy { parts.append(pocket.status) }
        return parts.isEmpty ? pocket.status : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: openPocket) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pocket.connected ? pocket.deviceName : name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if pocket.busy || pocket.reconnecting { ProgressView() }
                else if pocket.newOnPocket > 0 { Text("\(pocket.newOnPocket) new").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            }
        }.buttonStyle(.plain)
        if pocket.recordingOnDevice { LiveTranscriptView(live: pocket.live) }
    }
}

struct LiveTranscriptView: View {
    let live: LiveTranscriber?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Recording", systemImage: "record.circle").font(.caption.weight(.semibold)).foregroundStyle(.red)
            if let live {
                if let failed = live.failed { Text(failed).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(live.lines.suffix(4).enumerated()), id: \.offset) { _, line in Text(line).font(.callout) }
                if !live.interim.isEmpty { Text(live.interim).font(.callout).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AskLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var asking = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("What did we decide about pricing?", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5).focused($focused)
                    Button(action: ask) {
                        HStack { if asking { ProgressView() }; Text(asking ? "Searching recordings…" : "Ask") }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !answer.isEmpty { Text(.init(answer)).textSelection(.enabled) }
                }.padding(20)
            }
            .navigationTitle("Ask all recordings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { focused = true }
        }
    }

    private func ask() {
        focused = false; asking = true
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = LibraryAsk.context(library.recordings, question: text)
        Task {
            defer { asking = false }
            do { answer = try await AIConfiguration.chat(context, question: text) }
            catch { library.error = error.localizedDescription }
        }
    }
}

struct PeopleView: View {
    @Environment(LibraryStore.self) private var library
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        List {
            if library.people.isEmpty {
                ContentUnavailableView("No people yet", systemImage: "person.2", description: Text("Name a speaker in a transcript to see them here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(library.people, id: \.name) { person in
                NavigationLink { PersonView(name: person.name) } label: {
                    LabeledContent(person.name, value: "\(person.count)").monospacedDigit()
                }
                .swipeActions { Button("Rename") { newName = person.name; renaming = person.name } }
            }
        }
        .navigationTitle("People")
        .alert("Rename person", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let old = renaming { do { try library.renamePerson(old, to: newName) } catch { library.error = error.localizedDescription } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Use another person’s name to merge them.") }
    }
}

private struct PersonView: View {
    @Environment(LibraryStore.self) private var library
    let name: String

    var body: some View {
        List(library.recordings(with: name)) { item in
            NavigationLink(value: item.id) { RecordingRow(item: item, processing: false) }
        }.navigationTitle(name)
    }
}

struct CustomTemplatesView: View {
    @State private var templates = NotesTemplates.custom
    @State private var editing: CustomTemplate?

    var body: some View {
        List {
            ForEach(templates) { template in
                Button { editing = template } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name).foregroundStyle(.primary)
                        Text(template.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { templates.remove(atOffsets: $0); NotesTemplates.custom = templates }
        }
        .overlay { if templates.isEmpty { ContentUnavailableView("No custom styles", systemImage: "text.badge.plus") } }
        .navigationTitle("Note styles")
        .toolbar { Button("Add", systemImage: "plus") { editing = CustomTemplate(name: "", prompt: "") } }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { saved in
                if let index = templates.firstIndex(where: { $0.id == saved.id }) { templates[index] = saved } else { templates.append(saved) }
                NotesTemplates.custom = templates
            }
        }
    }
}

private struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var template: CustomTemplate
    var save: (CustomTemplate) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $template.name)
                TextField("For example: Bullet points only. List decisions first.", text: $template.prompt, axis: .vertical).lineLimit(4...10)
            }
            .navigationTitle("Note style").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(template); dismiss() }
                        .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty || template.prompt.trimmingCharacters(in: .whitespaces).isEmpty || template.prompt.count > 2_000)
                }
            }
        }
    }
}
