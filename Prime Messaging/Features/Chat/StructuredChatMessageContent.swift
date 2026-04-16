import Foundation

enum StructuredChatMessageContent: Equatable {
    case poll(question: String, options: [String])
    case list(title: String, items: [String])

    nonisolated static func parse(_ rawText: String?) -> StructuredChatMessageContent? {
        guard let rawText else { return nil }
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard let header = lines.first else { return nil }

        if header.hasPrefix("[Poll]") {
            let question = header
                .replacingOccurrences(of: "[Poll]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let options = lines.dropFirst().map(normalizedRow).filter { $0.isEmpty == false }
            guard question.isEmpty == false else { return nil }
            return .poll(question: question, options: options)
        }

        if header.hasPrefix("[List]") {
            let title = header
                .replacingOccurrences(of: "[List]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let items = lines.dropFirst().map(normalizedRow).filter { $0.isEmpty == false }
            guard title.isEmpty == false else { return nil }
            return .list(title: title, items: items)
        }

        return nil
    }

    nonisolated static func makePollText(question: String, options: [String]) -> String {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        return ([ "[Poll] \(normalizedQuestion)" ] + normalizedOptions.map { "- \($0)" })
            .joined(separator: "\n")
    }

    nonisolated static func makeListText(title: String, items: [String]) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        return ([ "[List] \(normalizedTitle)" ] + normalizedItems.map { "- \($0)" })
            .joined(separator: "\n")
    }

    var previewText: String {
        switch self {
        case let .poll(question, options):
            return options.isEmpty ? "Poll: \(question)" : "Poll: \(question) (\(options.count) options)"
        case let .list(title, items):
            return items.isEmpty ? "List: \(title)" : "List: \(title) (\(items.count) items)"
        }
    }

    nonisolated private static func normalizedRow(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["- ", "• ", "☐ ", "☑ ", "[ ] ", "[x] "]

        for prefix in prefixes where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
