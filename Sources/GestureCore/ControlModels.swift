import Foundation

enum GestureKind: String, Codable, CaseIterable, Identifiable {
    case rollPositive, rollNegative, pitchUp, pitchDown, shake
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rollPositive: return "Twist +"
        case .rollNegative: return "Twist −"
        case .pitchUp: return "Tilt up"
        case .pitchDown: return "Tilt down"
        case .shake: return "Double shake"
        }
    }
    var instruction: String {
        switch self {
        case .rollPositive: return "Twist past the positive angle, hold briefly, then return to neutral."
        case .rollNegative: return "Twist past the negative angle, hold briefly, then return to neutral."
        case .pitchUp: return "Tilt past the positive pitch angle, hold briefly, then return."
        case .pitchDown: return "Tilt past the negative pitch angle, hold briefly, then return."
        case .shake: return "Make two short shakes less than half a second apart, then settle."
        }
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case haptic, volumeUp, volumeDown, mute, playPause, nextTrack, previousTrack, nextSlide, previousSlide
    case phonePlayPause, phoneNext, phonePrevious, phonePing, shortcut, lightOn, lightOff, lightToggle, homeScene
    case spotifyPlayPause, spotifyNext, spotifyPrevious, spotifyVolumeUp, spotifyVolumeDown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spotifyPlayPause: return "Spotify · Play / pause"
        case .spotifyNext: return "Spotify · Next track"
        case .spotifyPrevious: return "Spotify · Previous track"
        case .spotifyVolumeUp: return "Spotify Connect · Volume up"
        case .spotifyVolumeDown: return "Spotify Connect · Volume down"
        case .haptic: return "Watch · Haptic only"
        case .volumeUp: return "Computer · Volume up"
        case .volumeDown: return "Computer · Volume down"
        case .mute: return "Computer · Mute / unmute"
        case .playPause: return "Computer · Play / pause"
        case .nextTrack: return "Computer · Next track"
        case .previousTrack: return "Computer · Previous track"
        case .nextSlide: return "Computer · Next slide / page"
        case .previousSlide: return "Computer · Previous slide / page"
        case .phonePlayPause: return "iPhone · Apple Music play / pause"
        case .phoneNext: return "iPhone · Apple Music next track"
        case .phonePrevious: return "iPhone · Apple Music previous track"
        case .phonePing: return "iPhone · Play locator chime"
        case .shortcut: return "iPhone · Run a Shortcut"
        case .lightOn: return "Home · Light / plug on"
        case .lightOff: return "Home · Light / plug off"
        case .lightToggle: return "Home · Toggle light / plug"
        case .homeScene: return "Home · Activate a scene"
        }
    }
    var computerCommand: String? {
        switch self {
        case .volumeUp: return "volume_up"
        case .volumeDown: return "volume_down"
        case .mute: return "mute"
        case .playPause: return "play_pause"
        case .nextTrack: return "next_track"
        case .previousTrack: return "previous_track"
        case .nextSlide: return "next_slide"
        case .previousSlide: return "previous_slide"
        default: return nil
        }
    }
    var isHomePower: Bool { [.lightOn, .lightOff, .lightToggle].contains(self) }
}

struct GestureBinding: Codable, Identifiable, Equatable {
    var gesture: GestureKind
    var action: ActionKind
    var enabled = true
    var targetID = ""
    var homeID = ""
    var targetName = ""
    var shortcutName = ""
    var id: String { gesture.rawValue }
    var summary: String { targetName.isEmpty ? action.title : "\(action.title) · \(targetName)" }
}

struct ControlProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var bindings: [GestureBinding]
}

struct WizardryConfiguration: Codable, Equatable {
    var schema = 1
    var revision = UUID().uuidString
    var selectedProfileID = "computer"
    var threshold = 0.65
    var armSeconds = 8.0
    var profiles: [ControlProfile] = [
        .init(id: "computer", name: "Computer", bindings: [
            .init(gesture: .rollPositive, action: .volumeUp), .init(gesture: .rollNegative, action: .volumeDown),
            .init(gesture: .pitchUp, action: .nextTrack), .init(gesture: .pitchDown, action: .previousTrack),
            .init(gesture: .shake, action: .playPause)]),
        .init(id: "phone", name: "Phone", bindings: [
            .init(gesture: .rollPositive, action: .shortcut, shortcutName: "Wizardry Volume Up"),
            .init(gesture: .rollNegative, action: .shortcut, shortcutName: "Wizardry Volume Down"),
            .init(gesture: .pitchUp, action: .spotifyNext), .init(gesture: .pitchDown, action: .spotifyPrevious),
            .init(gesture: .shake, action: .spotifyPlayPause)]),
        .init(id: "home", name: "Home", bindings: [
            .init(gesture: .rollPositive, action: .lightOn), .init(gesture: .rollNegative, action: .lightOff),
            .init(gesture: .pitchUp, action: .homeScene), .init(gesture: .pitchDown, action: .phonePing),
            .init(gesture: .shake, action: .lightToggle)])
    ]
    var selectedProfile: ControlProfile { profiles.first { $0.id == selectedProfileID } ?? profiles[0] }
    var supportsLiveVolume: Bool { ["computer", "phone"].contains(selectedProfileID) }
    var isValid: Bool {
        schema == 1 && !profiles.isEmpty && profiles.count <= 10 &&
        profiles.contains { $0.id == selectedProfileID } &&
        threshold.isFinite && (0.45...1.2).contains(threshold) &&
        armSeconds.isFinite && (3...20).contains(armSeconds) &&
        Set(profiles.map(\.id)).count == profiles.count &&
        profiles.allSatisfy { Set($0.bindings.map(\.gesture)).count == $0.bindings.count && $0.bindings.count <= 5 }
    }
}

struct MotionFrame: Codable, Identifiable {
    var id = UUID()
    var time: Double
    var roll: Double
    var pitch: Double
    var yaw: Double
    var ax: Double
    var ay: Double
    var az: Double
    var rx: Double
    var ry: Double
    var rz: Double
    var gx: Double
    var gy: Double
    var gz: Double
    var hz: Double
    var state: String
    // Optional for compatibility with previous Watch telemetry.
    var control: WatchControlSnapshot? = nil
}

/// Short-stroke estimate signed in the configured volume direction; not an
/// absolute hand position. Optional on telemetry from older Watch versions.
struct VolumeMotionFeedback: Codable, Equatable {
    var startingVolume: Double
    var travel: Double
    var velocity: Double
    var acceleration: Double
    var isValid: Bool {
        [startingVolume,travel,velocity,acceleration].allSatisfy(\.isFinite) && (0...1).contains(startingVolume)
    }
}

struct WatchControlSnapshot: Codable, Equatable {
    enum Phase: String, Codable {
        case unarmed, calibrating, armed, extending, volumeStarting, adjustingVolume, lockingVolume, locked, stopped, failed, enrolling
        var title: String {
            switch self {
            case .unarmed: return "Activate on Watch"
            case .calibrating: return "Hold still facing Watch"
            case .armed: return "Ready to extend"
            case .extending: return "Extending arm"
            case .volumeStarting: return "Reading current volume"
            case .adjustingVolume: return "Adjusting volume"
            case .lockingVolume: return "Locking volume"
            case .locked: return "Volume locked"
            case .stopped: return "Stopped · activate again"
            case .failed: return "Volume unconfirmed"
            case .enrolling: return "Learning finger tap"
            }
        }
    }
    var phase: Phase
    var profileID: String
    var relativeYaw: Double?
    var requestedVolume: Double?
    var acknowledgedVolume: Double?
    var dryRun: Bool
    var singleTapEnabled: Bool
    var singleTapStatus: String
    var armRemaining: Int
    var enrollmentRemaining: Int?
    var volumeMotion: VolumeMotionFeedback? = nil
    var isValid: Bool {
        [requestedVolume,acknowledgedVolume].allSatisfy {$0.map {$0.isFinite && (0...1).contains($0)} ?? true} &&
        (relativeYaw.map {$0.isFinite && abs($0) <= .pi+0.001} ?? true) &&
        (0...20).contains(armRemaining) && (enrollmentRemaining.map {(0...300).contains($0)} ?? true) &&
        singleTapStatus.count <= 500 && profileID.count <= 128 && (volumeMotion?.isValid ?? true)
    }
}

struct GestureRequest: Codable {
    var id = UUID()
    var createdAt = Date().timeIntervalSince1970
    var revision: String
    var profileID: String
    var gesture: GestureKind
}

struct ActionResult: Codable {
    enum Outcome: String, Codable { case executed, dryRun, handedOff, failed }
    var outcome: Outcome
    var message: String
    static func failure(_ message: String) -> Self { .init(outcome: .failed, message: message) }
}

/// Commands are never queued for later replay. Mark before execution, even if execution fails.
struct CommandGate {
    private var seen: [UUID: Double] = [:]
    private var lastAction = -Double.infinity
    mutating func accept(_ event: GestureRequest, configuration: WizardryConfiguration, now: Double) -> GestureBinding? {
        seen = seen.filter { now - $0.value < 30 }
        guard now.isFinite, event.createdAt.isFinite, abs(now - event.createdAt) <= 5,
              event.revision == configuration.revision, event.profileID == configuration.selectedProfileID,
              seen[event.id] == nil, now - lastAction >= 0.3,
              let binding = configuration.selectedProfile.bindings.first(where: { $0.gesture == event.gesture && $0.enabled }) else { return nil }
        seen[event.id] = now
        lastAction = now
        return binding
    }
}
