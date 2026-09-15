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
    }
}
