import SwiftUI

@main
struct CodeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        Settings {
            SettingsView(appState: appDelegate.appState)
                .frame(minWidth: 560, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(l10n["settings_ellipsis"]) {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .commands {
            // The real settings are SettingsWindowController's window. While it
            // is open the app is a regular app with a menu bar, and the generated
            // "Settings…" (⌘,) would open this empty scene as a blank window.
            CommandGroup(replacing: .appSettings) {
                Button(l10n["settings_ellipsis"]) {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
