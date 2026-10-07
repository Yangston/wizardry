import Foundation

enum InteractionEndReason: String, Codable {
    case replaced, settingsChanged, explicitStop, navigation, enrollment, background
    case activationInterrupted, activationTimeout, armedExpired, runtimeExpired, systemStopped
    case volumeLocked, volumeStopped, staleMotion, motionGap, invalidMotion, sensorFailure, transportFailure
    case inactivity // Decode historical traces from builds with a stationary timeout.
}

struct InteractionDiagnosticEvent: Codable, Equatable {
    var uptime: Double
    var event: String
    var scene: String
    var application: String
    var requested: Bool
    var enabled: Bool
    var rotated: Bool
    var reducedLuminance: Bool
}

/// Bounded, credential-free evidence. Requested autorotation is not proof that
/// watchOS kept the physical display awake. The luminance flag is UI evidence.
struct InteractionDiagnosticsSnapshot: Codable, Equatable {
    var recordedAt: Double
    var scene: String
    var application: String
    var requested: Bool
    var enabled: Bool
    var rotated: Bool
    var reducedLuminance: Bool
    var motionHz: Double
    var rawHz: Double
    var sampleAgeMS: Double
    var processingDelayMS: Double
    var maximumGapMS: Double
    var confirmedUpdateHz: Double
    var roundTripMS: Double
    var outstandingUpdates: Int
    var lastStop: InteractionEndReason?
    var events: [InteractionDiagnosticEvent]
    var isValid: Bool {
        [recordedAt,motionHz,rawHz,sampleAgeMS,processingDelayMS,maximumGapMS,confirmedUpdateHz,roundTripMS].allSatisfy { $0.isFinite && $0 >= 0 } &&
        (0...4).contains(outstandingUpdates) &&
        scene.count <= 32 && application.count <= 32 && events.count <= 48 &&
        events.allSatisfy { $0.uptime.isFinite && $0.event.count <= 80 && $0.scene.count <= 32 && $0.application.count <= 32 }
    }
}

struct InteractionDiagnostics {
    private var sampleTimes: [Double] = []
    private var lastSample: Double?
    private(set) var motionHz = 0.0
    private(set) var rawHz = 0.0
    private(set) var sampleAgeMS = 0.0
    private(set) var processingDelayMS = 0.0
    private(set) var maximumGapMS = 0.0
    private(set) var lastStop: InteractionEndReason?
    private(set) var events: [InteractionDiagnosticEvent] = []

    mutating func restore(_ snapshot: InteractionDiagnosticsSnapshot) {
        guard snapshot.isValid else { return }
        events = snapshot.events; lastStop = snapshot.lastStop
    }

    mutating func beginCapture() {
        sampleTimes = []; lastSample = nil; motionHz = 0; rawHz = 0
        sampleAgeMS = 0; processingDelayMS = 0; maximumGapMS = 0
    }
    mutating func observe(sample: Double, callback: Double, processed: Double, rawRate: Double) {
        guard [sample,callback,processed,rawRate].allSatisfy(\.isFinite),
              sample <= callback, callback <= processed, rawRate >= 0,
              lastSample.map({sample > $0}) ?? true else { return }
        if let lastSample { maximumGapMS = max(maximumGapMS,(sample-lastSample)*1000) }
        lastSample = sample
        sampleTimes.append(sample)
        sampleTimes.removeAll { sample-$0 > 1 }
        if sampleTimes.count > 200 { sampleTimes.removeFirst(sampleTimes.count-200) }
        if let first = sampleTimes.first, sample > first { motionHz = Double(sampleTimes.count-1)/(sample-first) }
        rawHz = rawRate; sampleAgeMS = (processed-sample)*1000
        processingDelayMS = (processed-callback)*1000
    }
    mutating func record(_ event: InteractionDiagnosticEvent, stop: InteractionEndReason? = nil) {
        if let stop { lastStop = stop }
        events.append(event)
        if events.count > 48 { events.removeFirst(events.count-48) }
    }
}
