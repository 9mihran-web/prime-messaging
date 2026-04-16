import Foundation

extension String {
    nonisolated var localized: String {
        LocalizationManager.shared.localizedString(for: self)
    }
}

enum LocalizationManager {
    nonisolated static let shared = LocalizationManagerImpl()
}

final class LocalizationManagerImpl {
    private let languageKey = "selected_app_language"

    nonisolated func localizedString(for key: String) -> String {
        let selectedLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? AppLanguage.english.rawValue)

        if
            let selectedLanguage,
            let path = Bundle.main.path(forResource: selectedLanguage.rawValue, ofType: "lproj"),
            let bundle = Bundle(path: path)
        {
            let localized = NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
            if localized != key {
                return localized
            }
        }

        if
            let englishPath = Bundle.main.path(forResource: AppLanguage.english.rawValue, ofType: "lproj"),
            let englishBundle = Bundle(path: englishPath)
        {
            let englishLocalized = NSLocalizedString(key, tableName: nil, bundle: englishBundle, value: key, comment: "")
            if englishLocalized != key {
                return englishLocalized
            }
        }

        return NSLocalizedString(key, comment: "")
    }
}
