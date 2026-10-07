import Foundation

/// App command routing only. Apple Watch pairing remains managed by watchOS.
struct ControlConnectionRequest: Codable {
    enum Operation: String, Codable { case status, connect, disconnect }
    var id = UUID()
    var createdAt = Date().timeIntervalSince1970
    var operation: Operation
    var profileID: String? = nil
    var isValid: Bool {
        createdAt.isFinite && (profileID.map {!$0.isEmpty && $0.count <= 128} ?? true)
    }
}

struct ControlConnectionReply: Codable {
    var id: UUID
    var configuration: WizardryConfiguration
    var targetReady: Bool
    var message: String
    var liveVolumeReady: Bool? = nil
    var isValid: Bool { configuration.isValid && message.count <= 1000 }
}
