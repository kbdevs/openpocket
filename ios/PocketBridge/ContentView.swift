import SwiftUI

struct ContentView: View {
    @Environment(PocketDeviceController.self) private var pocket
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(openPocket: { selectedTab = 1 }).tabItem { Label("Recordings", systemImage: "waveform") }.tag(0)
            SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(1)
        }
        .fullScreenCover(isPresented: Binding(get: { !onboardingDone && pocket.rememberedDevice == nil }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView { onboardingDone = true }
        }
    }
}

struct LibraryView: View {
    var openPocket: () -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(ProcessingController.self) private var processor
    @Environment(PocketDeviceController.self) private var pocket
    @State private var query = ""
    @State private var pendingDelete: Recording?
    @State private var asking = false

    /// Recordings grouped by calendar day, newest first.
    private var days: [(day: Date, items: [Recording])] {
        Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var visible: [Recording] {
        library.recordings.filter { item in
            query.isEmpty || item.searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let saved = pocket.rememberedDevice, query.isEmpty {
                    Section { PocketStatusCard(name: saved.name, openPocket: openPocket) }
                }
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "No recordings yet" : "No recordings found", systemImage: query.isEmpty ? "waveform" : "magnifyingglass")
                    } description: {
                        Text(query.isEmpty ? "Sync recordings from your Pocket to see them here." : "Try a different title, transcript, or folder.")
                    } actions: {
                        if query.isEmpty {
                            Button("Connect Pocket", systemImage: "externaldrive") { openPocket() }
                                .labelStyle(.titleAndIcon)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.listRowBackground(Color.clear)
                } else {
                    ForEach(days, id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.items) { item in
                                NavigationLink(value: item.id) { RecordingRow(item: item, processing: processor.active.contains(item.id), showsDate: false) }
                                    .swipeActions(edge: .trailing) { Button("Delete", role: .destructive) { pendingDelete = item } }
                                    .swipeActions(edge: .leading) {
                                        if item.status == "failed" { Button("Retry", systemImage: "arrow.clockwise") { processor.process(item.id) }.tint(.indigo) }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { PeopleView() } label: { Label("People", systemImage: "person.2") }
                    if AIConfiguration.canMakeNotes && !library.recordings.isEmpty {
                        Button { asking = true } label: { Label("Ask all recordings", systemImage: "sparkles") }
                    }
                }
            }
            .sheet(isPresented: $asking) {
                AskView(title: "Ask all recordings", suggestions: ["What did I commit to this week?", "What decisions were made recently?", "Who did I talk to most?"]) {
                    LibraryAsk.context(library.recordings, question: $0)
                }
            }
            .searchable(text: $query, prompt: "Titles, transcripts, people")
            .navigationDestination(for: UUID.self) { RecordingDetailView(id: $0) }
            .confirmationDialog("Delete \(pendingDelete?.title ?? "recording")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete from iPhone", role: .destructive) {
                    if let id = pendingDelete?.id { processor.cancel(id); change { try library.delete(id) } }
                    pendingDelete = nil
                }
            } message: { Text("The recording on your Pocket and the service copy will stay.") }
        }
    }

    private func change(_ action: () throws -> Void) { do { try action() } catch { library.error = error.localizedDescription } }
}

struct RecordingRow: View {
    let item: Recording
    var processing: Bool
    var showsDate = true
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(2)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(showsDate ? item.listMetadata : item.timeMetadata).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if processing { ProgressView().accessibilityLabel("Processing") }
            else if item.status == "failed" { Text("Failed").font(.caption.weight(.medium)).foregroundStyle(.red) }
        }.padding(.vertical, 4)
    }
}

extension Recording {
    /// Date, length and folder. The source is left out because every recording comes from Pocket.
    var listMetadata: String {
        let date = Calendar.current.isDateInToday(createdAt)
            ? createdAt.formatted(date: .omitted, time: .shortened)
            : createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return [date, timeLabel(duration), folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Start time, length and folder, for rows under a day heading.
    var timeMetadata: String {
        [createdAt.formatted(date: .omitted, time: .shortened), timeLabel(duration), folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct RecordingDetailView: View {
    let id: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(ProcessingController.self) private var processor
    @Environment(AudioController.self) private var audio
    @Environment(VoiceProfileStore.self) private var voice
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var section = "Notes"
    @State private var editTitle = false
    @State private var title = ""
    @State private var editSpeaker: String?
    @State private var speakerName = ""
    @State private var folder = ""
    @State private var editFolder = false
    @State private var template = "meeting"
    @State private var generating = false
    @State private var asking = false
    @State private var removeRemote = false
    @State private var exportURL: URL?
    @State private var editingSegment: TranscriptSegment?
    @State private var editedText = ""
    @State private var enrollingSpeaker: String?
    @State private var reviewingVoice: String?
    private var item: Recording? { library.recording(id) }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.largeTitle.bold()).textSelection(.enabled)
                            Text(item.listMetadata).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        playback(item)
                        if voice.working { ProgressView(voice.status ?? "Checking voices…").font(.callout) }
                        if let error = item.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                        if processor.active.contains(id) {
                            HStack { ProgressView(); Text(item.status == "uploading" ? "Uploading audio…" : item.status == "transcribing" ? "Transcribing and finding speakers…" : "Preparing transcript and notes…").font(.callout) }
                        } else if (!item.hasSpeechCheckpoint && item.status != "complete") || item.status == "failed" || ["queued", "processing", "uploading", "transcribing", "summarizing"].contains(item.status) {
                            Button { processor.process(id) } label: { Label(item.status == "failed" ? "Retry processing" : item.backendID != nil ? "Resume processing" : AIConfiguration.canMakeNotes ? "Transcribe and make notes" : "Transcribe", systemImage: "text.badge.waveform") }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Picker("View", selection: $section) { Text("Notes").tag("Notes"); Text("Transcript").tag("Transcript") }.pickerStyle(.segmented)
                        switch section {
                        case "Transcript": transcript(item)
                        default: notes(item)
                        }
                    }.padding(20)
                }
                .background(Color(.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if AIConfiguration.canMakeNotes && !item.segments.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { asking = true } label: { Label("Ask", systemImage: "sparkles") }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Rename", systemImage: "pencil") { title = item.title; editTitle = true }
                            Button("Set folder", systemImage: "folder") { folder = item.folder; editFolder = true }
                            ShareLink(item: library.audioURL(item)) { Label("Share audio", systemImage: "waveform") }
                            ShareLink(item: item.exportText) { Label("Share notes and transcript", systemImage: "square.and.arrow.up") }
                            Button("Export Markdown", systemImage: "doc.text") { export(item) }
                            if !item.segments.isEmpty && AIConfiguration.canMakeNotes {
                                Menu("Make notes again", systemImage: "arrow.clockwise") {
                                    ForEach(NotesTemplates.all, id: \.key) { style in
                                        Button(style.name) { template = NotesTemplates.value(for: style.key); regenerate(item) }
                                    }
                                }.disabled(generating)
                            }
                            if item.backendID != nil { Button("Remove service copy", systemImage: "cloud.slash", role: .destructive) { removeRemote = true } }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
                .task(id: id) { do { try audio.load(item, url: library.audioURL(item)) } catch { library.error = "Playback is not available for this file. \(error.localizedDescription)" } }
            } else { ContentUnavailableView("Recording not found", systemImage: "waveform") }
        }
        .sheet(isPresented: $asking) {
            AskView(title: item?.title ?? "Ask", suggestions: ["What were the decisions?", "What are my action items?", "Summarize this in three bullets"]) { _ in
                library.recording(id)?.namedSegments ?? []
            }
        }
        .alert("Rename recording", isPresented: $editTitle) {
            TextField("Title", text: $title)
            Button("Save") { if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { change { try library.update(id) { $0.title = title; $0.titleIsLocal = true } } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Speaker name", isPresented: Binding(get: { editSpeaker != nil }, set: { if !$0 { editSpeaker = nil } })) {
            TextField("Name", text: $speakerName)
            Button("Save") {
                if let speaker = editSpeaker { change { try library.update(id) { $0.speakerNames[speaker] = speakerName.isEmpty ? nil : speakerName } } }
                editSpeaker = nil
            }
            Button("Cancel", role: .cancel) { editSpeaker = nil }
        }
        .confirmationDialog(voice.hasProfile ? "Replace your voice profile?" : "Save your voice profile?", isPresented: Binding(get: { enrollingSpeaker != nil }, set: { if !$0 { enrollingSpeaker = nil } }), titleVisibility: .visible) {
            Button("Save my voice") {
                if let speaker = enrollingSpeaker { voice.enroll(recordingID: id, speaker: speaker) }
                enrollingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { enrollingSpeaker = nil }
        } message: { Text("Use this speaker’s audio to save your voice on this iPhone and suggest matches in other Pocket recordings. Choose a speaker with at least ten seconds of clear speech.") }
        .confirmationDialog("Is this your voice?", isPresented: Binding(get: { reviewingVoice != nil }, set: { if !$0 { reviewingVoice = nil } }), titleVisibility: .visible) {
            Button("That’s me") {
                if let speaker = reviewingVoice { change { try voice.confirmMatch(recordingID: id, speaker: speaker) } }
                reviewingVoice = nil
            }
            Button("Not me") {
                if let speaker = reviewingVoice { change { try voice.rejectMatch(recordingID: id, speaker: speaker) } }
                reviewingVoice = nil
            }
            Button("Cancel", role: .cancel) { reviewingVoice = nil }
        } message: { Text("Play this speaker’s audio before you confirm. A confirmed match uses You in the transcript. Tap Make notes again to update saved notes.") }
        .alert("Folder", isPresented: $editFolder) {
            TextField("Folder name", text: $folder)
            Button("Save") { change { try library.update(id) { $0.folder = folder } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove the audio and notes from your service?", isPresented: $removeRemote, titleVisibility: .visible) {
            Button("Remove service copy", role: .destructive) {
                Task {
                    do {
                        processor.cancel(id)
                        if let remoteID = item?.backendID {
                            let client = try BackendClient.configured()
                            if let address = item?.backendURL, address != client.baseURL.absoluteString { throw PocketError.message("Use the recording’s original service URL in Settings before you remove its copy.") }
                            try await client.delete(remoteID)
                        }
                        try library.update(id) { $0.backendID = nil; $0.backendURL = nil; $0.status = $0.segments.isEmpty ? "local" : "complete" }
                    } catch { library.error = error.localizedDescription }
                }
            }
        } message: { Text("Your iPhone copy will stay.") }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
        .sheet(item: $editingSegment) { segment in
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    TextEditor(text: $editedText).font(.body).padding(8).accessibilityLabel("Transcript text")
                    Text("Make notes again after an edit to update the summary.").font(.footnote).foregroundStyle(.secondary)
                }.padding(16).navigationTitle("Edit transcript").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingSegment = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                change { try library.update(id) { local in if let index = local.segments.firstIndex(where: { $0.id == segment.id }) { local.segments[index].text = editedText } } }
                                editingSegment = nil
                            }.disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
    }

    private func playback(_ item: Recording) -> some View {
        let currentTime = audio.activeID == id ? audio.currentTime : 0
        let duration = audio.activeID == id ? audio.duration : item.duration
        return VStack(spacing: 12) {
            Slider(value: Binding(get: { currentTime }, set: { audio.seek($0) }), in: 0...max(1, duration))
                .accessibilityLabel("Playback position")
            HStack {
                Text(timeLabel(currentTime))
                Spacer()
                Text(timeLabel(duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button { audio.skip(-15) } label: {
                    Label("Back 15 seconds", systemImage: "gobackward.15").labelStyle(.iconOnly)
                        .font(.title2).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                Button { audio.toggle() } label: {
                    Label(audio.playing ? "Pause" : "Play", systemImage: audio.playing ? "pause.fill" : "play.fill").labelStyle(.iconOnly)
                        .font(.title2).frame(width: 58, height: 58).background(.indigo, in: Circle()).foregroundStyle(.white)
                }
                Button { audio.skip(15) } label: {
                    Label("Forward 15 seconds", systemImage: "goforward.15").labelStyle(.iconOnly)
                        .font(.title2).frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }.frame(maxWidth: .infinity)
            HStack {
                Button { change { try library.update(id) { $0.bookmarks.append(currentTime) } } } label: {
                    Label("Bookmark", systemImage: "bookmark").font(.caption).frame(minHeight: 44)
                }
                Spacer()
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in Button("\(speed.formatted())×") { audio.rate = Float(speed) } }
                } label: { Text("\(Double(audio.rate).formatted())×").font(.caption.bold()).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue("\(Double(audio.rate).formatted()) times")
            }
            if !item.bookmarks.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(Array(item.bookmarks.enumerated()), id: \.offset) { index, time in
                        Button(timeLabel(time), systemImage: "bookmark.fill") { audio.seek(time) }.buttonStyle(.bordered)
                            .contextMenu { Button("Remove bookmark", role: .destructive) { change { try library.update(id) { $0.bookmarks.remove(at: index) } } } }
                    } }
                }
            }
        }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .disabled(audio.activeID != id)
    }

    private func notes(_ item: Recording) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if generating { HStack { ProgressView(); Text("Making notes…") }.font(.callout) }
            if item.summary.isEmpty {
                if !processor.active.contains(id) && !generating { Text("No notes yet.").foregroundStyle(.secondary) }
            }
            else { Text(.init(item.summary)).textSelection(.enabled) }
            if !item.actions.isEmpty {
                Text("Action items").font(.title3.bold())
                ForEach(item.actions) { action in
                    Button {
                        change { try library.update(id) { local in if let index = local.actions.firstIndex(where: { $0.id == action.id }) { local.actions[index].done.toggle(); local.actionsAreLocal = true } } }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: action.done ? "checkmark.circle.fill" : "circle").foregroundStyle(action.done ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) { Text(action.text).strikethrough(action.done); if let owner = action.owner { Text(item.speakerName(owner)).font(.caption).foregroundStyle(.secondary) } }
                            Spacer()
                        }.padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(action.text)
                        .accessibilityValue(action.done ? "Complete" : "Incomplete")
                        .accessibilityHint(action.done ? "Mark incomplete" : "Mark complete")
                }
            }
        }
    }

    private func transcript(_ item: Recording) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if item.segments.isEmpty { Text("No transcript yet.").foregroundStyle(.secondary) }
            ForEach(item.segments) { segment in
                let current = audio.activeID == id && audio.currentTime >= segment.start && audio.currentTime < segment.end
                let header = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
                VStack(alignment: .leading, spacing: 8) {
                    header {
                        Menu {
                            Button("Rename speaker", systemImage: "pencil") { editSpeaker = segment.speaker; speakerName = item.speakerName(segment.speaker) }
                            let known = library.people.map(\.name).filter { $0 != item.speakerName(segment.speaker) }
                            if !known.isEmpty {
                                Menu("Name as", systemImage: "person.2") {
                                    ForEach(known, id: \.self) { name in
                                        Button(name) { change { try library.update(id) { $0.speakerNames[segment.speaker] = name } } }
                                    }
                                }
                            }
                            Button("This is my voice", systemImage: "person.crop.circle.badge.checkmark") { enrollingSpeaker = segment.speaker }.disabled(voice.working)
                            if let match = item.voiceMatches?[segment.speaker], !match.rejected {
                                Button(match.confirmed ? "Review voice match" : "Review possible match") { reviewingVoice = segment.speaker }
                            }
                        } label: {
                            Text(item.speakerName(segment.speaker)).font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }
                        if !textSize.isAccessibilitySize { Spacer() }
                        Button { audio.seek(segment.start); audio.resume() } label: {
                            Text(timeLabel(segment.start)).font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Play from \(timeLabel(segment.start))")
                    }
                    if let match = item.voiceMatches?[segment.speaker], !match.confirmed && !match.rejected {
                        Button { reviewingVoice = segment.speaker } label: {
                            Label("Possible match: You · Review", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.caption).frame(minHeight: 44)
                        }
                    }
                    Text(segment.text).textSelection(.enabled).foregroundStyle(current ? .primary : .secondary)
                        .contextMenu { Button("Edit transcript", systemImage: "pencil") { editedText = segment.text; editingSegment = segment } }
                }.padding(14).background(current ? Color.indigo.opacity(0.06) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func regenerate(_ item: Recording) {
        generating = true
        Task {
            defer { generating = false }
            do {
                let response = try await AIConfiguration.summarize(item.namedSegments, template: template)
                guard library.recording(id)?.namedSegments == item.namedSegments else { throw PocketError.message("The transcript changed. Tap Make notes again to use your edits.") }
                try library.update(id) { if $0.titleIsLocal != true { $0.title = response.title }; $0.summary = response.summary; $0.actions = response.actions; $0.summaryIsLocal = true; $0.actionsAreLocal = true }
            } catch { library.error = error.localizedDescription }
        }
    }
    private func export(_ item: Recording) {
        do {
            let url = URL.temporaryDirectory.appendingPathComponent("\(item.id.uuidString).md")
            try item.exportText.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch { library.error = error.localizedDescription }
    }
    private func change(_ action: () throws -> Void) { do { try action() } catch { library.error = error.localizedDescription } }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
