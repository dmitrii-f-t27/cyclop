import AppKit
import SwiftUI
import Translation

/// Asks macOS to download a language pair, in a window that can host the
/// system's confirmation sheet.
///
/// The notch panel cannot do this itself. It is a borderless non-activating
/// window, and `prepareTranslation()` waits for a download confirmation that
/// has nowhere to appear over it — the request hangs rather than failing, which
/// is why the pane used to send people to System Settings instead. An ordinary
/// window gives that sheet a parent, so the one thing only the user can do —
/// press "Download" — is visible and the pack actually arrives.
@MainActor
final class LanguagePackInstaller: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LanguagePackInstaller()

    private var window: NSWindow?

    /// Opens the installer for one pair. The callback fires only when macOS
    /// reports the pair as installed, so the caller can re-run the translation
    /// that was waiting for it.
    func present(
        source: Locale.Language,
        target: Locale.Language,
        onInstalled: @escaping @MainActor () -> Void
    ) {
        // One window at a time: the sheet is modal to it, and a second copy
        // would sit behind the first with nothing to show.
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = LanguagePackView(source: source, target: target) { [weak self] installed in
            self?.dismiss()
            if installed { onInstalled() }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = localized("Language Packs")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // Cyclop is an accessory app: it has no Dock icon to click, so the
        // window has to come forward by itself or it opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func dismiss() {
        window?.close()
        window = nil
    }
}

private struct LanguagePackView: View {
    let source: Locale.Language
    let target: Locale.Language
    let onFinished: (Bool) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var message = ""
    @State private var working = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Downloading %@ → %@", Translator.name(source), Translator.name(target)))
                .font(.system(size: 13, weight: .semibold))

            HStack(alignment: .top, spacing: 8) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(message.isEmpty
                     ? localized("Confirm the download in the system dialog.")
                     : message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(localized("Translation Languages…")) { Translator.openLanguageSettings() }
                Spacer(minLength: 8)
                Button(localized("Close")) { onFinished(false) }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .pointerStyle(.default)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        .translationTask(configuration) { session in
            await prepare(session)
        }
    }

    /// The session is `sending` and can only cross into one task; the request
    /// and the status check both live here so it is consumed once.
    private func prepare(_ session: sending TranslationSession) async {
        do {
            try await session.prepareTranslation()
            let status = await LanguageAvailability().status(from: source, to: target)
            working = false

            switch status {
            case .installed:
                onFinished(true)
            case .supported:
                message = localized("macOS still reports the pack as not installed. Try the system settings.")
            default:
                message = localized("macOS does not translate this pair of languages.")
            }
        } catch {
            working = false
            // A cancelled sheet lands here too; the wording is the
            // system's, and "cancelled" is a perfectly clear answer.
            message = error.localizedDescription
        }
    }
}
