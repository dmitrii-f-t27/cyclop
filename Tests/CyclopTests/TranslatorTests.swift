import Foundation
import Testing
import Translation
@testable import Cyclop

/// The direction rule of the translate tab, without a window: which end of the
/// pair the chosen language lands on.
///
/// The pane itself is not tested — see CONTRIBUTING.md — but this rule is pure
/// and is the part that decides what `TranslationSession` is asked for.
@MainActor
struct TranslatorTests {

    @Test func latinTextGoesFromTheChosenLanguageToRussian() {
        let route = Translator.route(for: "Hallo, wie geht es dir?", language: .german)
        #expect(route.source == Locale.Language(identifier: "de"))
        #expect(route.target == Translator.russian)
    }

    @Test func cyrillicGoesFromRussianToTheChosenLanguage() {
        let route = Translator.route(for: "Привет, как дела?", language: .german)
        #expect(route.source == Translator.russian)
        #expect(route.target == Locale.Language(identifier: "de"))
    }

    @Test func thaiTextGoesToRussian() {
        let route = Translator.route(for: "สวัสดี", language: .thai)
        #expect(route.source == Locale.Language(identifier: "th"))
        #expect(route.target == Translator.russian)
    }

    @Test func russianGoesOutToThai() {
        let route = Translator.route(for: "Привет", language: .thai)
        #expect(route.source == Translator.russian)
        #expect(route.target == Locale.Language(identifier: "th"))
    }

    /// Brazilian Portuguese has to keep its region: the framework ships `pt`
    /// and `pt-BR` as different packs, and a bare `pt` is the European one.
    @Test func portugueseKeepsItsBrazilianRegion() {
        let route = Translator.route(for: "Olá, tudo bem?", language: .portuguese)
        #expect(route.source == Locale.Language(identifier: "pt-BR"))
        #expect(route.source.region?.identifier == "BR")
        #expect(route.target == Translator.russian)
    }

    @Test func emptyTextAsksForTheIncomingDirection() {
        let route = Translator.route(for: "", language: .english)
        #expect(route.source == Locale.Language(identifier: "en"))
        #expect(route.target == Translator.russian)
    }

    @Test func theDefaultChoiceIsStillEnglish() {
        #expect(Translator.route(for: "hello").source == Locale.Language(identifier: "en"))
    }
}
