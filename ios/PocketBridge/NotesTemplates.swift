import Foundation

/// A user-written instruction for how notes should read.
struct CustomTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
}

/// Built-in and custom note styles. Keys are built-in names or a custom template's UUID.
enum NotesTemplates {
    static let builtIns: [(name: String, key: String)] = [("Meeting", "meeting"), ("Lecture", "lecture"), ("Journal", "journal"), ("General", "general")]
    static let defaultKey = "notesTemplate"
    private static let customKey = "customTemplates"

    static var custom: [CustomTemplate] {
        get { UserDefaults.standard.data(forKey: customKey).flatMap { try? JSONDecoder().decode([CustomTemplate].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customKey) }
    }

    static var all: [(name: String, key: String)] { builtIns + custom.map { ($0.name, $0.id.uuidString) } }

    static var selected: String { UserDefaults.standard.string(forKey: defaultKey) ?? "meeting" }

    /// The value sent to the AI client: a built-in name, or "custom:" and the user's instruction.
    static func value(for key: String) -> String {
        if builtIns.contains(where: { $0.key == key }) { return key }
        if let template = custom.first(where: { $0.id.uuidString == key }) { return "custom:" + template.prompt }
        return "meeting"
    }
}
