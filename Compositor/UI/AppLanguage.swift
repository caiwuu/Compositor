import AppKit
import SwiftUI

/// The language Compositor shows itself in, chosen from the app menu. macOS reads the choice once, at launch, so a
/// change takes effect when the app is next opened.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Each language is listed in itself, so it can be found whatever the app is showing.
    var name: String {
        switch self {
        case .system: String(localized: "System Language")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    private static let key = "AppleLanguages"

    /// Read from the app's own defaults: the shared domain always has the system's list.
    static var current: AppLanguage {
        guard let identifier = Bundle.main.bundleIdentifier,
              let chosen = UserDefaults.standard.persistentDomain(forName: identifier)?[key] as? [String],
              let first = chosen.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    static func choose(_ language: AppLanguage, restart: @escaping () -> Void) {
        guard language != current else { return }
        if language == .system { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set([language.rawValue], forKey: key) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Compositor to change its language?")
        alert.informativeText = String(localized: "The new language is used the next time Compositor opens.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }
}

extension String {
    /// This text in the app's language, for text that reaches the screen as a `String` built or stored elsewhere:
    /// a case's raw value, a title passed to an AppKit control. Text missing from the string catalog shows as is.
    var localized: String { Bundle.main.localizedString(forKey: self, value: nil, table: nil) }
}

extension RawRepresentable where RawValue == String {
    /// The case's name on screen. Raw values stay English, since some are saved in projects.
    var localizedName: String { rawValue.localized }
}
