import Foundation

/// Receiver time sampled in an authenticated reply. Use receipt time, not an
/// RTT midpoint: the return-trip delay makes the translated request older,
/// never artificially fresher. Original Watch/phone expiry is checked first.
struct ReceiverClockAlignment {
    let serverTime: Double
    let receivedAt: Double
    func translate(createdAt: Double, now: Double) -> Double? {
        guard [serverTime,receivedAt,createdAt,now].allSatisfy(\.isFinite),
              now >= receivedAt, now-receivedAt <= 30,
              createdAt <= now+0.1, now-createdAt <= 1 else { return nil }
        let translated = createdAt + (serverTime-receivedAt)
        return translated.isFinite ? translated : nil
    }
}
