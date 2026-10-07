import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

/// Experimental foreground bridge through a stock MPVolumeView. Public slider
/// events are not a documented system-volume setter; actual readback is required.
@MainActor
final class PhoneVolumeController: ObservableObject {
    @Published private(set) var readinessMessage: String? = "Show the iPhone volume slider to check readiness"
    @Published private(set) var lastReadback: Double?
    @Published private(set) var lastRequested: Double?
    @Published private(set) var lastFailure: String?
    private let views = NSHashTable<MPVolumeView>.weakObjects()
    private var sessionID: UUID?
    private var routeID: String?
    private var lastRequest = 0.0
    private var generation = 0
    private var audioSessionActive = false
    private var expiryTask: Task<Void,Never>?
    private var maximumTask: Task<Void,Never>?
    private var previousIdleTimerDisabled: Bool?
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { sessionID != nil }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isActive, self.routeID != self.currentRouteID {
                    self.stop(); self.lastFailure = "iPhone audio output changed. Activate again."
                }
                self.refreshReadiness()
            }
        })
        observers.append(center.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isActive { self.stop(); self.lastFailure = "iPhone left the foreground. Activate again." }
                self.refreshReadiness()
            }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func register(_ view: MPVolumeView) { views.add(view); refreshReadiness() }
    func unregister(_ view: MPVolumeView) { views.remove(view); refreshReadiness() }
    func refreshReadiness() {
        let current = inspectReadiness()
        if readinessMessage != current { readinessMessage = current }
    }
    /// A newly selected Phone card needs one layout turn. This only observes
    /// readiness for a bounded interval; it never writes volume or retries one.
    func waitForReadiness() async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime+0.2
        repeat {
            refreshReadiness()
            if readinessMessage == nil { return nil }
            guard !Task.isCancelled else { return "Connection check cancelled" }
            do { try await Task.sleep(for:.milliseconds(20)) }
            catch { return "Connection check cancelled" }
        } while ProcessInfo.processInfo.systemUptime < deadline
        refreshReadiness()
        return readinessMessage
    }
    func stop() {
        expiryTask?.cancel(); expiryTask = nil
        maximumTask?.cancel(); maximumTask = nil
        generation += 1; sessionID = nil; routeID = nil; lastRequest = 0
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }
    private var currentRouteID: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid).sorted().joined(separator:"|")
    }
    private func inspectReadiness() -> String? {
        #if targetEnvironment(simulator)
        return "Live iPhone volume requires a physical iPhone"
        #else
        guard UIApplication.shared.applicationState == .active else {
            return "Open Wizardry on iPhone; a locked or background phone cannot control media volume"
        }
        guard views.allObjects.contains(where:isVisible) else {
            return "Keep the native iPhone volume slider visible on Control, Live, or Setup"
        }
        guard !currentRouteID.isEmpty else {
            return "No active iPhone audio output; select a speaker or headphones"
        }
        guard nativeSlider() != nil else {
            return "This output has no visible enabled volume slider; try iPhone speaker or headphones"
        }
        return nil
        #endif
    }
    private func isVisible(_ view: UIView) -> Bool {
        guard let window = view.window, !window.isHidden,
              view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var visibleRect = view.convert(view.bounds,to:window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return false }
            if current.clipsToBounds {
                visibleRect = visibleRect.intersection(current.convert(current.bounds,to:window))
            }
            guard !visibleRect.isNull, !visibleRect.isEmpty else { return false }
            ancestor = current.superview
        }
        return true
    }
    private func nativeSlider() -> UISlider? {
        for view in views.allObjects where view.showsVolumeSlider && isVisible(view) {
            view.layoutIfNeeded()
            var descendants = view.subviews
            while let child = descendants.popLast() {
                if let slider = child as? UISlider, slider.isEnabled, isVisible(slider),
                   slider.maximumValue > slider.minimumValue { return slider }
                descendants.append(contentsOf:child.subviews)
            }
        }
        return nil
    }
    private func fail(_ message: String, request: VolumeRequest) -> VolumeReply {
        stop(); lastFailure = message; refreshReadiness()
        return .failure(message,request:request)
    }
    func volume(_ request: VolumeRequest) async -> VolumeReply {
        let now = Date().timeIntervalSince1970
        guard request.isValid, request.createdAt <= now+0.1, now < request.createdAt+1 else {
            return fail("Invalid or expired iPhone volume request; activate again",request:request)
        }
        refreshReadiness()
        if let readinessMessage { return fail(readinessMessage,request:request) }
        if request.operation == .begin {
            stop(); lastFailure = nil; lastRequested = nil
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.ambient,mode:.default)
                try audio.setActive(true)
                audioSessionActive = true
            } catch { return fail("Cannot read iPhone volume: "+error.localizedDescription,request:request) }
            sessionID = request.sessionID; routeID = currentRouteID
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            let leaseGeneration = generation
            maximumTask = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(10*60)) } catch { return }
                guard let self, self.generation == leaseGeneration else { return }
                self.stop()
            }
        } else {
            guard sessionID == request.sessionID, now-lastRequest <= 6,
                  routeID == currentRouteID else {
                return fail("iPhone volume session expired or audio output changed. Activate again.",request:request)
            }
        }
        let audio = AVAudioSession.sharedInstance()
        guard !currentRouteID.isEmpty, let slider = nativeSlider(),
              request.createdAt+1 > Date().timeIntervalSince1970 else {
            return fail("iPhone volume slider or output became unavailable, or the request expired",request:request)
        }
        lastRequest = now
        let operationGeneration = generation
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(6)) } catch { return }
            guard let self, self.generation == operationGeneration else { return }
            self.stop()
        }
        let previous = Double(audio.outputVolume)
        guard previous.isFinite, (0...1).contains(previous) else {
            return fail("iPhone output-volume readback is unavailable",request:request)
        }
        if let target = request.target {
            lastRequested = target
            // One attempt using public control events, followed only by reads.
            // No private selector lookup, fake touches, or automatic resend.
            slider.setValue(Float(target),animated:false)
            slider.sendActions(for:[.valueChanged,.touchUpInside])
        }
        let end = min(request.createdAt+1,Date().timeIntervalSince1970+0.4)
        while true {
            guard generation == operationGeneration, sessionID == request.sessionID,
                  UIApplication.shared.applicationState == .active, routeID == currentRouteID,
                  nativeSlider() != nil, Date().timeIntervalSince1970 < end, !Task.isCancelled else {
                return fail("iPhone volume interrupted, expired, or output changed; not retried",request:request)
            }
            let actual = Double(audio.outputVolume)
            let confirmed = actual.isFinite && (0...1).contains(actual) &&
                (request.target.map { VolumeReadback.confirms(actual:actual,target:$0,previous:previous) } ?? true)
            if confirmed {
                // Return exactly the sample that passed the target comparison.
                lastReadback = actual; lastFailure = nil
                if request.operation == .end { stop() }
                return .init(outcome:.executed,message:request.operation == .end ? "iPhone volume confirmed · session closed" : "iPhone media volume confirmed",
                             sessionID:request.sessionID,sequence:request.sequence,volume:actual)
            }
            if Date().timeIntervalSince1970+0.01 >= end {
                if actual.isFinite, (0...1).contains(actual) { lastReadback = actual }
                let target = request.target.map { String(format:"%.1f%%",$0*100) } ?? "current volume"
                return fail("iPhone did not confirm \(target); read back \(String(format:"%.1f%%",actual*100)). Stopped; not retried.",request:request)
            }
            do { try await Task.sleep(for:.milliseconds(10)) }
            catch { return fail("iPhone volume interrupted; not retried",request:request) }
        }
    }
}

/// Apple disallows subclassing MPVolumeView. Track lifecycle on an ordinary
/// UIView host containing an unmodified native volume view instead.
@MainActor
final class PhoneVolumeView: UIView {
    let volumeView = MPVolumeView(frame:.zero)
    weak var controller: PhoneVolumeController?
    override init(frame: CGRect) {
        super.init(frame:frame)
        volumeView.showsVolumeSlider = true
        addSubview(volumeView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        volumeView.frame = bounds
        let controller = controller
        Task { @MainActor in controller?.refreshReadiness() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let controller = controller, view = volumeView, attached = window != nil
        Task { @MainActor in
            if attached { controller?.register(view) }
            else { controller?.unregister(view) }
        }
    }
}
