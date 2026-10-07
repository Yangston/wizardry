import Foundation

/// Native motion samples for recording. Angles/rates are radians and rad/s;
/// acceleration/gravity are g. Missing sensors stay nil, never invented zeroes.
struct SensorFrame: Codable {
    var time: Double
    var wallTime: Double
    var ax: Double; var ay: Double; var az: Double
    var rx: Double; var ry: Double; var rz: Double
    var gx: Double; var gy: Double; var gz: Double
    var roll: Double; var pitch: Double; var yaw: Double
    var qx: Double; var qy: Double; var qz: Double; var qw: Double
    var rawAx: Double? = nil; var rawAy: Double? = nil; var rawAz: Double? = nil
    var rawTime: Double? = nil
    var mx: Double? = nil; var my: Double? = nil; var mz: Double? = nil
    var magneticAccuracy: Int = -1
    var isValid: Bool {
        let values = [time,wallTime,ax,ay,az,rx,ry,rz,gx,gy,gz,roll,pitch,yaw,qx,qy,qz,qw]
        let optional = [rawAx,rawAy,rawAz,rawTime,mx,my,mz]
        return values.allSatisfy(\.isFinite) && time >= 0 && wallTime >= 0 &&
            optional.allSatisfy {$0.map(\.isFinite) ?? true} && (-1...3).contains(magneticAccuracy)
    }
}

struct SensorBatch: Codable {
    struct Metadata: Codable {
        var requestedSampleHz = 100
        var watchModel: String
        var watchOS: String
        var referenceFrame = "xArbitraryZVertical"
    }
    var schema = 1
    var sessionID: UUID
    var batchSequence: Int
    var createdAt = Date().timeIntervalSince1970
    var samples: [SensorFrame]
    var droppedSamples: Int
    var recording: Bool
    var metadata: Metadata?
    var isValid: Bool {
        schema == 1 && batchSequence >= 0 && createdAt.isFinite && droppedSamples >= 0 &&
        (1...200).contains(samples.count) && samples.allSatisfy(\.isValid) &&
        zip(samples.dropFirst(),samples).allSatisfy {$0.0.time > $0.1.time}
    }
}

struct DesktopMappingEdit: Codable {
    var id: UUID
    var revision: String
    var profileID: String
    var bindings: [GestureBinding]
    func applying(to configuration: WizardryConfiguration) -> WizardryConfiguration? {
        let allowed: Set<ActionKind> = [.haptic,.volumeUp,.volumeDown,.mute,.playPause,.nextTrack,.previousTrack,.nextSlide,.previousSlide,
                                       .phonePlayPause,.phoneNext,.phonePrevious,.phonePing,.shortcut,
                                       .spotifyPlayPause,.spotifyNext,.spotifyPrevious,.spotifyVolumeUp,.spotifyVolumeDown]
        guard revision == configuration.revision, ["computer","phone"].contains(profileID),
              let index = configuration.profiles.firstIndex(where:{$0.id == profileID}), bindings.count <= 5,
              Set(bindings.map(\.gesture)) == Set(configuration.profiles[index].bindings.map(\.gesture)),
              Set(bindings.map(\.gesture)).count == bindings.count else { return nil }
        let old = configuration.profiles[index].bindings
        guard bindings.allSatisfy({ binding in
            if old.contains(binding) { return true } // Preserve untouched legacy bindings.
            return allowed.contains(binding.action) && binding.action.isAllowed(inProfile:profileID) && binding.targetID.isEmpty &&
                binding.homeID.isEmpty && binding.targetName.isEmpty && binding.shortcutName.count <= 200 &&
                (binding.action != .shortcut || !binding.shortcutName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }) else { return nil }
        var next = configuration; next.profiles[index].bindings = bindings
        return next.isValid ? next : nil
    }
}

struct DesktopStudioPoll: Codable {
    var operation = "poll"
    var createdAt = Date().timeIntervalSince1970
    var configuration: WizardryConfiguration
    var appliedMappingEditID: UUID? = nil
    var mappingError: String? = nil
    var watchRecording = false
}

struct DesktopStudioReply: Codable {
    var ok: Bool
    var studioProtocol: Int
    var telemetryRequested: Bool
    var recording: Bool
    var pendingMappingEdit: DesktopMappingEdit?
    var serverTime: Double?
}
