import SwiftUI

@main
struct WizardryApp: App {
    @StateObject private var motion = MotionController.shared
    var body: some Scene { WindowGroup { ContentView(motion:motion,link:motion.link) } }
}
