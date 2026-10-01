import AppIntents
import Foundation

// Compile the same intent in both apps so it can be added to a shortcut on
// iPhone and executed locally by the installed watch companion.
struct StartWizardrySession: AppIntent {
    static var title: LocalizedStringResource = "Start Wizardry session"
    static var description = IntentDescription("Run on your watch to open Wizardry. Hold still for the ready haptic, then make a control gesture. Starts a 30-minute session. Armed gestures tolerate brief dimming while motion remains available.")
    static var openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        #if os(watchOS)
        MotionController.shared.activateFromShortcut()
        #else
        throw WatchActivationError.runOnWatch
        #endif
        return .result()
    }
}

private enum WatchActivationError: LocalizedError {
    case runOnWatch
    var errorDescription: String? {
        "Run this shortcut on your Apple Watch to activate Wizardry. Enable Show on Apple Watch in the shortcut's details, then assign it to an AssistiveTouch hand gesture."
    }
}

struct WizardryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent:StartWizardrySession(),phrases:["Start a session in \(.applicationName)","Start \(.applicationName)"],shortTitle:"Start session",systemImageName:"wand.and.stars")
    }
}
