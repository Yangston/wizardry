import Combine
import Foundation
import HomeKit

struct HomeTarget: Identifiable, Hashable {
    var id: String
    var homeID: String
    var name: String
}

@MainActor
final class HomeController: NSObject, ObservableObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {
    @Published private(set) var devices: [HomeTarget] = []
    @Published private(set) var scenes: [HomeTarget] = []
    @Published private(set) var status = "Connect Apple Home to choose lights, plugs, and scenes"
    private var manager: HMHomeManager?
    func connect() {
        guard manager == nil else { refresh(); return }
        status = "Requesting Apple Home access…"
        manager = HMHomeManager(); manager?.delegate = self
    }
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) { Task { @MainActor in self.refresh() } }
    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { Task { @MainActor in self.refresh() } }
    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) { Task { @MainActor in self.refresh() } }
    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) { Task { @MainActor in self.refresh() } }
    nonisolated func home(_ home: HMHome, didAdd actionSet: HMActionSet) { Task { @MainActor in self.refresh() } }
    nonisolated func home(_ home: HMHome, didRemove actionSet: HMActionSet) { Task { @MainActor in self.refresh() } }
    private func power(_ accessory: HMAccessory) -> HMCharacteristic? {
        accessory.services.filter { [HMServiceTypeLightbulb,HMServiceTypeOutlet,HMServiceTypeSwitch].contains($0.serviceType) }
            .flatMap(\.characteristics).first { $0.characteristicType == HMCharacteristicTypePowerState && $0.properties.contains(HMCharacteristicPropertyWritable) }
    }
    func refresh() {
        guard let manager else { return }
        devices = []; scenes = []
        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories where power(accessory) != nil {
                accessory.delegate = self
                devices.append(.init(id:accessory.uniqueIdentifier.uuidString,homeID:home.uniqueIdentifier.uuidString,
                                     name:"\(home.name) · \(accessory.room?.name ?? "Room") · \(accessory.name)"))
            }
            scenes += home.actionSets.map { .init(id:$0.uniqueIdentifier.uuidString,homeID:home.uniqueIdentifier.uuidString,name:"\(home.name) · \($0.name)") }
        }
        devices.sort { $0.name < $1.name }; scenes.sort { $0.name < $1.name }
        if manager.authorizationStatus.contains(.authorized) { status = "\(devices.count) lights / plugs · \(scenes.count) scenes" }
        else { status = "Allow Wizardry in Settings → Privacy & Security → HomeKit" }
    }
    func perform(_ binding: GestureBinding, deadline: Double) async -> ActionResult {
        guard let manager else { return .failure("Connect Apple Home in Setup first") }
        guard let home = manager.homes.first(where: { $0.uniqueIdentifier.uuidString == binding.homeID }) else {
            return .failure("Choose a Home target in this gesture's settings")
        }
        if binding.action == .homeScene {
            guard let scene = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == binding.targetID }) else { return .failure("Scene unavailable; choose it again") }
            return await withCheckedContinuation { continuation in
                home.executeActionSet(scene) { error in
                    continuation.resume(returning: error.map { .failure($0.localizedDescription) } ?? .init(outcome:.executed,message:"Scene: \(scene.name)"))
                }
            }
        }
        guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == binding.targetID }),
              accessory.isReachable, let characteristic = power(accessory) else { return .failure("Light / plug unavailable; check Apple Home") }
        if binding.action == .lightToggle {
            let error: Error? = await withCheckedContinuation { continuation in characteristic.readValue { continuation.resume(returning:$0) } }
            if let error { return .failure(error.localizedDescription) }
        }
        guard Date().timeIntervalSince1970 <= deadline else { return .failure("Home command expired; try again") }
        let on: Bool
        if binding.action == .lightToggle {
            guard let current = characteristic.value as? NSNumber else { return .failure("Cannot read current power state") }
            on = !current.boolValue
        } else { on = binding.action == .lightOn }
        return await withCheckedContinuation { continuation in
            characteristic.writeValue(on) { error in
                continuation.resume(returning:error.map { .failure($0.localizedDescription) } ?? .init(outcome:.executed,message:"\(accessory.name): \(on ? "on" : "off")"))
            }
        }
    }
}
