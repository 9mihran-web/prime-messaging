import Foundation

enum PhoneCallURLBuilder {
    static func makeURL(from rawPhoneNumber: String) -> URL? {
        let trimmed = rawPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = ""
        for (index, character) in trimmed.enumerated() {
            if character.isNumber {
                normalized.append(character)
            } else if character == "+", index == 0 {
                normalized.append(character)
            }
        }

        guard normalized.isEmpty == false else { return nil }
        return URL(string: "tel://\(normalized)")
    }
}
