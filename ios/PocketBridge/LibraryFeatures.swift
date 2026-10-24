import Foundation

extension LibraryStore {
    /// Names given to speakers, with the number of recordings each appears in.
    var people: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for recording in recordings {
            for name in Set(recording.speakerNames.values) where !name.isEmpty { counts[name, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    func recordings(with person: String) -> [Recording] {
        recordings.filter { $0.speakerNames.values.contains(person) }
    }

    /// Renames a person in every recording. Renaming to a name that exists merges the two.
    func renamePerson(_ old: String, to new: String) throws {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        for recording in recordings where recording.speakerNames.values.contains(old) {
            try update(recording.id) { local in
                for (label, value) in local.speakerNames where value == old { local.speakerNames[label] = name }
            }
        }
    }
}

/// Builds one chat context from many recordings: every summary, plus full transcripts of the best matches.
enum LibraryAsk {
    static func context(_ recordings: [Recording], question: String, limitBytes: Int = 100_000) -> [TranscriptSegment] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }
        let scored = recordings.map { recording -> (Recording, Int) in
            let text = recording.searchableText.lowercased()
            return (recording, words.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 })
        }
        let ordered = scored.sorted { $0.1 == $1.1 ? $0.0.createdAt > $1.0.createdAt : $0.1 > $1.1 }
        var segments: [TranscriptSegment] = []
        var bytes = 0
        func add(_ segment: TranscriptSegment) -> Bool {
            let size = segment.speaker.utf8.count + segment.text.utf8.count + 80
            guard bytes + size <= limitBytes else { return false }
            bytes += size; segments.append(segment); return true
        }
        for (recording, score) in ordered {
            let label = "\(recording.title) · \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))"
            let overview = recording.summary.isEmpty ? String(recording.transcriptText.prefix(600)) : recording.summary
            guard !overview.isEmpty, add(TranscriptSegment(id: "\(recording.id)-summary", speaker: label, start: 0, end: 0, text: overview)) else { continue }
            guard score > 0 else { continue }
            for segment in recording.namedSegments {
                let line = TranscriptSegment(id: "\(recording.id)-\(segment.id)", speaker: "\(label) · \(segment.speaker)", start: segment.start, end: segment.end, text: segment.text)
                if !add(line) { break }
            }
        }
        return segments
    }
}
