import SwiftUI
import AppIntents

@main
struct WizardryApp: App {
    @StateObject private var motion = MotionController.shared
    var body: some Scene { WindowGroup { ContentView(motion:motion,link:motion.link) } }
}

struct StartWizardrySession: AppIntent {
    static var title: LocalizedStringResource = "Start Wizardry session"
    static var description = IntentDescription("Open Wizardry and start a 30-minute gesture control session. Detection pauses when the app is inactive.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        MotionController.shared.start()
        return .result()
    }
}
struct WizardryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent:StartWizardrySession(),phrases:["Start a session in \(.applicationName)","Start \(.applicationName)"],shortTitle:"Start session",systemImageName:"wand.and.stars")
    }
}
