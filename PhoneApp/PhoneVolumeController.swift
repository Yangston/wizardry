import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Experimental foreground bridge through the native volume control. iOS has
/// no documented system-volume setter; this uses public UISlider operations,
/// never private class names/selectors, and requires actual audio readback.
@MainActor
final class PhoneVolumeController {
    private let views = NSHashTable<MPVolumeView>.weakObjects()
    private var sessionID: UUID?
    private var routeID: String?
    private var lastRequest = 0.0
    private var generation = 0
    private var audioSessionActive = false
    private var expiryTask: Task<Void,Never>?
    var isActive: Bool { sessionID != nil }

    func register(_ view: MPVolumeView) { views.add(view) }
    func unregister(_ view: MPVolumeView) { views.remove(view) }
    func stop() {
        expiryTask?.cancel(); expiryTask = nil
        generation += 1; sessionID = nil; routeID = nil; lastRequest = 0
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }
    private var currentRouteID: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid).sorted().joined(separator:"|")
    }
    private func nativeSlider() -> UISlider? {
        for view in views.allObjects {
            guard let window = view.window, !view.isHidden, view.alpha > 0,
                  view.convert(view.bounds,to:window).intersects(window.bounds) else { continue }
            var ancestor = view.superview
            var visible = true
            while let parent = ancestor {
                if parent.isHidden || parent.alpha == 0 { visible = false; break }
                ancestor = parent.superview
            }
            guard visible else { continue }
            // Inspect only public UIView/UISlider types. No private API lookup.
            if let slider = view.subviews.compactMap({$0 as? UISlider}).first,
               slider.isEnabled { return slider }
        }
        return nil
    }
    private func fail(_ message: String, request: VolumeRequest) -> VolumeReply {
        stop(); return .failure(message,request:request)
    }
    func volume(_ request: VolumeRequest) async -> VolumeReply {
        #if targetEnvironment(simulator)
        return fail("iPhone system volume needs a physical device; the Simulator cannot change it",request:request)
        #else
        let now = Date().timeIntervalSince1970
        guard request.isValid, request.createdAt <= now+0.1, now-request.createdAt <= 1,
              UIApplication.shared.applicationState == .active,
              let slider = nativeSlider() else {
            return fail("Keep Wizardry open on iPhone with the native volume slider visible on Control, Live, or Setup",request:request)
        }
        if request.operation == .begin {
            stop()
            do {
                // Ambient mixes with existing music. No sound or extra runtime
                // is created to keep the app alive.
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.ambient,mode:.default)
                try audio.setActive(true)
                audioSessionActive = true
            } catch { return fail("Cannot read iPhone volume: "+error.localizedDescription,request:request) }
            sessionID = request.sessionID; routeID = currentRouteID
        } else {
            guard sessionID == request.sessionID, now-lastRequest <= 6,
                  routeID == currentRouteID else {
                return fail("iPhone volume session expired or audio output changed. Activate again.",request:request)
            }
        }
        let audio = AVAudioSession.sharedInstance()
        guard !currentRouteID.isEmpty, request.createdAt+1 > Date().timeIntervalSince1970 else {
            return fail("No iPhone audio output, or volume request expired",request:request)
        }
        lastRequest = now
        let operationGeneration = generation
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(6)) } catch { return }
            guard let self, self.generation == operationGeneration else { return }
            self.stop()
        }
        if let target = request.target {
            // One write only. Polling below reads the audio session; it never
            // resends the command if the system declines it.
            slider.setValue(Float(target),animated:false)
            slider.sendActions(for:[.valueChanged,.touchUpInside])
            let end = min(request.createdAt+1,Date().timeIntervalSince1970+0.4)
            while !VolumeReadback.confirms(actual:Double(audio.outputVolume),target:target) {
                guard Date().timeIntervalSince1970 < end, !Task.isCancelled else {
                    return fail("iPhone did not confirm the requested volume. Stopped; not retried.",request:request)
                }
                do { try await Task.sleep(for:.milliseconds(10)) }
                catch { return fail("iPhone volume interrupted; not retried",request:request) }
                guard generation == operationGeneration, UIApplication.shared.applicationState == .active,
                      routeID == currentRouteID, nativeSlider() != nil else {
                    return fail("iPhone volume interrupted or audio output changed. Activate again.",request:request)
                }
            }
        }
        let actual = Double(audio.outputVolume)
        guard actual.isFinite, (0...1).contains(actual), generation == operationGeneration,
              UIApplication.shared.applicationState == .active, routeID == currentRouteID,
              request.createdAt+1 > Date().timeIntervalSince1970 else {
            return fail("iPhone volume readback unavailable or expired",request:request)
        }
        if request.operation == .end { stop() }
        return .init(outcome:.executed,message:request.operation == .end ? "iPhone volume confirmed · session closed" : "iPhone media volume confirmed",
                     sessionID:request.sessionID,sequence:request.sequence,volume:actual)
        #endif
    }
}

@MainActor
final class PhoneVolumeView: MPVolumeView {
    weak var controller: PhoneVolumeController?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { controller?.register(self) }
        else { controller?.unregister(self) }
    }
}
