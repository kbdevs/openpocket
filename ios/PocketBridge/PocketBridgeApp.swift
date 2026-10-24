import SwiftUI
import UserNotifications

@main
struct PocketBridgeApp: App {
    @State private var library: LibraryStore
    @State private var processor: ProcessingController
    @State private var voice: VoiceProfileStore
    @State private var audio = AudioController()
    @State private var pocket: PocketDeviceController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let library = LibraryStore()
        _library = State(initialValue: library)
        let voice = VoiceProfileStore(library: library)
        _voice = State(initialValue: voice)
        let processor = ProcessingController(library: library, voice: voice)
        _processor = State(initialValue: processor)
        let pocket = PocketDeviceController(library: library)
        pocket.onImport = { id in
            if UserDefaults.standard.object(forKey: "autoProcessImports") as? Bool ?? true { processor.process(id) }
        }
        _pocket = State(initialValue: pocket)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library).environment(processor).environment(audio).environment(pocket).environment(voice)
                .tint(.indigo)
                .task { if pocket.rememberedDevice != nil { Notifier.requestPermission() }; pocket.connectRemembered(); await library.recoverLegacyRecordings(); processor.resumePending() }
                .onChange(of: audio.error) { _, error in if let error { library.error = error } }
                .onChange(of: voice.error, initial: true) { _, error in if let error { library.error = error } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { processor.resumePending(); pocket.connectRemembered(); pocket.refreshBattery() }
                }
                .alert("Cannot complete the action", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                    Button("OK") { library.error = nil }
                } message: { Text(library.error ?? "") }
        }
    }
}
