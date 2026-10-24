import EventKit

/// Sends open action items to Apple Reminders.
enum Reminders {
    static func add(_ actions: [ActionItem], from recording: Recording) async throws -> Int {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw PocketError.message("Allow Reminders access in Settings to add action items.")
        }
        guard let list = store.defaultCalendarForNewReminders() else { throw PocketError.message("Reminders has no default list.") }
        let open = actions.filter { !$0.done }
        for action in open {
            let reminder = EKReminder(eventStore: store)
            reminder.title = action.text
            reminder.notes = "From \(recording.title) · \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))"
            reminder.calendar = list
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return open.count
    }
}
