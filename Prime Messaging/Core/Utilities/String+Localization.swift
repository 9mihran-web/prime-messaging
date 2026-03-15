import Foundation

extension String {
    var localized: String {
        LocalizationManager.shared.localizedString(for: self)
    }
}

enum LocalizationManager {
    static let shared = LocalizationManagerImpl()
}

final class LocalizationManagerImpl {
    private let languageKey = "selected_app_language"

    func localizedString(for key: String) -> String {
        guard
            let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? AppLanguage.english.rawValue),
            let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, comment: "")
        }

        return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }
}
