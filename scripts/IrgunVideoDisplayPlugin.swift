import Foundation
import Capacitor
import UIKit
import CoreMotion

// iOS-specific presentation policy. NEVER creates or replaces a media player.
// iPad/iPhone geometry, sensor-driven fullscreen and idle-lock are independent
// of the WKWebView video decoder and AVPlayer background audio session.
@objc(IrgunVideoDisplayPlugin)
public class IrgunVideoDisplayPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IrgunVideoDisplayPlugin"
    public let jsName = "IrgunVideoDisplay"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "playback", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setFullscreen", returnType: CAPPluginReturnPromise)
    ]

    private let motion = CMMotionManager()
    private var videoActive = false
    private var playbackIntended = false
    private var mini = false
    private var pip = false
    private var fullscreen = false
    private var manualExitBlocked = false
    private var manualExitAt = Date.distantPast
    private var sensorCandidate = ""
    private var sensorCandidateSince = Date.distantPast
    private var lastReported = ""
    private var orientationGeneration = 0

    @objc public func playback(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.videoActive = call.getBool("active") ?? false
            self.playbackIntended = call.getBool("playing") ?? false
            self.mini = call.getBool("mini") ?? false
            self.pip = call.getBool("pip") ?? false
            // A paused lecture does not hold the screen awake indefinitely.
            UIApplication.shared.isIdleTimerDisabled =
                self.videoActive && self.playbackIntended && !self.pip
            if self.videoActive && !self.mini && !self.pip { self.startMotionIfNeeded() }
            else { self.motion.stopDeviceMotionUpdates(); self.sensorCandidate = ""; self.lastReported = "" }
            if !self.videoActive && self.fullscreen {
                self.fullscreen = false
                self.manualExitBlocked = false
                self.applyOrientation(landscape: false, direction: "")
            }
            call.resolve()
        }
    }

    @objc public func setFullscreen(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let enabled = call.getBool("enabled") ?? false
            let fromSensor = call.getBool("fromSensor") ?? false
            let direction = call.getString("direction") ?? ""
            let chosenDirection = direction.isEmpty && self.sensorCandidate.hasPrefix("landscape")
                ? self.sensorCandidate : direction
            if !enabled && !fromSensor {
                // A manual fullscreen exit must remain respected even if an
                // earlier sensor callback already changed the orientation flag.
                self.manualExitBlocked = true
                self.manualExitAt = Date()
            }
            if enabled { self.manualExitBlocked = false }
            self.fullscreen = enabled
            self.applyOrientation(landscape: enabled, direction: chosenDirection)
            call.resolve()
        }
    }

    private func applyOrientation(landscape: Bool, direction: String) {
        guard let delegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let mask: UIInterfaceOrientationMask = landscape
            ? (direction == "landscapeRight" ? .landscapeRight : .landscapeLeft)
            : .portrait
        orientationGeneration += 1
        let generation = orientationGeneration
        delegate.irgunSetVideoOrientationMask(mask)
        if !landscape {
            // Restore normal rotation rules after the portrait transition. A
            // delayed old exit must never cancel a subsequent fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self, self.orientationGeneration == generation,
                      !self.fullscreen else { return }
                delegate.irgunSetVideoOrientationMask(.all)
            }
        }
    }

    private func startMotionIfNeeded() {
        guard motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates(to: OperationQueue.main) { [weak self] sample, _ in
            guard let self = self, let gravity = sample?.gravity,
                self.videoActive, !self.mini, !self.pip else { return }
            // Gravity-based orientation works with system auto-rotate disabled.
            // Hysteresis avoids a series of landscape/portrait oscillations.
            let candidate: String
            if abs(gravity.x) > 0.78 && abs(gravity.y) < 0.58 {
                candidate = gravity.x > 0 ? "landscapeRight" : "landscapeLeft"
            } else if gravity.y < -0.78 && abs(gravity.x) < 0.58 {
                candidate = "portrait"
            } else {
                self.sensorCandidate = ""
                return
            }
            if candidate != self.sensorCandidate {
                self.sensorCandidate = candidate
                self.sensorCandidateSince = Date()
                return
            }
            if Date().timeIntervalSince(self.sensorCandidateSince) < 0.75 { return }
            if candidate == "portrait" &&
                Date().timeIntervalSince(self.manualExitAt) >= 1.5 {
                // Clear suppression only after the device has genuinely been
                // observed upright following the manual exit. Forced UIKit
                // rotation should not immediately re-enter landscape.
                self.manualExitBlocked = false
            }
            if candidate != "portrait" && self.manualExitBlocked { return }
            if candidate == self.lastReported { return }
            self.lastReported = candidate
            let landscape = candidate != "portrait"
            // Changing only UI presentation: playback is controlled by JS.
            if landscape != self.fullscreen || landscape {
                self.notifyListeners("orientation", data: [
                    "fullscreen": landscape,
                    "direction": candidate
                ])
            }
        }
    }

    deinit {
        motion.stopDeviceMotionUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
