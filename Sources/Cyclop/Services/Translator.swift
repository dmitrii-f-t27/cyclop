import AppKit
import Translation

/// The languages that may stand on the non-Russian side of the translate tab.
///
/// Russian is fixed as one end: the pair the tab is built around is "Russian
/// and the language I am dealing with". Which way the pair runs is still read
/// from the script of the text, so one choice covers both directions — German
/// text goes to Russian, Cyrillic goes to German — and the same holds for Thai
/// and Portuguese.
///
/// The list is deliberately short. macOS translates a few dozen languages, but
/// a picker is for the languages somebody actually switches between; the rest
/// are one `Locale.Language` away if the list ever has to grow.
enum TranslateLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"
    case portuguese = "pt-BR"
    case thai = "th"

    var id: String { rawValue }

    var language: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Badge in the picker, where four names have to line up in one column.
    var code: String {
        switch self {
        case .english: "EN"
        case .german: "DE"
        case .portuguese: "PT"
        case .thai: "TH"
        }
    }

    /// The name in the language itself. A picker is the one place where
    /// "Deutsch" is more useful than "German": whoever is looking for their
    /// own language recognises it without first translating the menu.
    var nativeName: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        case .portuguese: "Português (Brasil)"
        case .thai: "ไทย"
        }
    }
}

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op, and the language is
    /// part of the identity because switching it has to start a new run even
    /// when the text has not moved.
    struct Request: Equatable {
        var text: String
        var attempt: Int
        var language: TranslateLanguage
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false

    /// The foreign half of the pair, and the only half the user picks.
    ///
    /// Kept in `config.json` rather than in this object: it is a preference
    /// about the person, not about the text currently in the field, and it
    /// should survive a relaunch the way the tab switches do.
    @Published var language: TranslateLanguage {
        didSet {
            guard language != oldValue else { return }
            ConfigStore.shared.translateLanguage = language.rawValue
            // The old result belongs to the old pair. Drop it before the new
            // session arrives, or the panel shows a German translation under a
            // Thai heading for as long as the request takes.
            output = ""
            failure = nil
            needsDownload = false
        }
    }

    private var attempt = 0

    init() {
        let saved = ConfigStore.shared.translateLanguage
        language = TranslateLanguage(rawValue: saved) ?? .english
    }

    var request: Request { Request(text: input, attempt: attempt, language: language) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { Self.route(for: trimmed, language: language) }

    /// Russian goes out to the chosen language, everything else comes in to
    /// Russian.
    ///
    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably, and "привет" comes back as Bulgarian
    /// often enough to matter. The choice of foreign language decides the other
    /// end; the script decides which way round the pair runs.
    static func route(for text: String, language: TranslateLanguage = .english) -> Route {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic
            ? Route(source: russian, target: language.language)
            : Route(source: language.language, target: russian)
    }

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: sending TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        // No language pack ships installed. `prepareTranslation()` is what asks
        // for one, but it blocks until its system prompt is answered — and that
        // prompt has nowhere to appear over a borderless panel of an app that
        // never activates, so it would hang forever. Check instead, and send
        // the user to the one place that can actually install it.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let localized = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        // Portuguese is the one pair where the code alone is ambiguous: the
        // pack is Brazilian, and a bare "Portuguese" would not tell which of
        // the two variants the panel is set to.
        let name = code == "pt" && language.region?.identifier == "BR"
            ? "\(localized) (BR)"
            : localized
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short code for the header badge — "EN → RU" reads at a glance where a
    /// spelled-out name would not fit in the strip.
    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
