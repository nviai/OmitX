import Foundation
import AppKit

/// Display strings outside SwiftUI views (modules, notes, errors…), translated to the app's language.
/// Keys are Vietnamese; translations live in Localization/Localizable.xcstrings.
/// The parameter is a `String.LocalizationValue` so the compiler extracts the strings (-emit-localized-strings).
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

/// UI language. Changing it = writing "AppleLanguages" for this app only, then relaunching.
enum AppLanguage {
    /// Language codes that have translations (.lproj folder names).
    static var available: [String] { languages(from: Bundle.main.localizations) }

    /// Bundle.localizations merges CFBundleLocalizations (Info.plist) and .lproj folders without deduplicating.
    static func languages(from localizations: [String]) -> [String] {
        var seen = Set<String>()
        let codes = localizations.filter { $0 != "Base" && seen.insert($0).inserted }
        return codes.isEmpty ? ["vi"] : codes
    }

    /// Language the user picked for this app (nil = follow the system).
    static var override: String? {
        get {
            // Only counts as an override when written in the app's domain (not the global one).
            let appDomain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            return (appDomain["AppleLanguages"] as? [String])?.first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    /// Language currently displayed.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "vi" }

    /// Relaunches the app to apply the new language.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// A language's name in that language ("Tiếng Việt", "日本語"…).
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
