import SwiftUI

struct SettingsView: View {
    @Environment(VoiceProfileStore.self) private var voice
    @AppStorage("defaultLanguage") private var language = "en"
    @AppStorage("autoProcessImports") private var autoProcess = true
    @AppStorage(NotesTemplates.defaultKey) private var notesStyle = "meeting"
    @AppStorage("customTemplates") private var customTemplates: Data?  // Refreshes the style picker after edits.
    @State private var result: String?
    @State private var deletingVoice = false

    var body: some View {
        @Bindable var voice = voice
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-process recordings", isOn: $autoProcess)
                    Picker("Note style", selection: $notesStyle) {
                        ForEach(NotesTemplates.all, id: \.key) { Text($0.name).tag($0.key) }
                    }
                    NavigationLink("Custom note styles") { CustomTemplatesView() }
                    Picker("Language", selection: $language) {
                        Text("English").tag("en"); Text("Spanish").tag("es"); Text("French").tag("fr"); Text("German").tag("de"); Text("Multilingual").tag("multi")
                    }
                }
                if voice.hasProfile || voice.working || result != nil {
                Section("My voice") {
                    if voice.hasProfile {
                        LabeledContent("My voice", value: "Saved on this iPhone")
                        Toggle("Suggest my voice", isOn: $voice.enabled)
                        Button("Check saved recordings") { voice.scanLibrary() }.disabled(voice.working || !voice.enabled)
                        Button("Delete voice profile", role: .destructive) { deletingVoice = true }
                    }
                    if voice.working {
                        ProgressView(voice.status ?? "Checking voices…")
                        Button("Stop voice check", role: .cancel) { voice.cancel() }
                    }
                    if let result { Text(result).font(.footnote).foregroundStyle(.orange) }
                }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete your voice profile?", isPresented: $deletingVoice, titleVisibility: .visible) {
                Button("Delete voice profile", role: .destructive) {
                    do { try voice.deleteProfile() } catch { result = error.localizedDescription }
                }
            } message: { Text("This removes your saved voice profile and its matches. Recordings and manual speaker names stay.") }
        }
    }
}
