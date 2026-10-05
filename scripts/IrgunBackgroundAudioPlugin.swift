import Foundation
import Capacitor
import AVFoundation
import MediaPlayer
import UIKit
import WebKit

// Prepare while the WebView is active. Home/lock starts AVPlayer from a native
// lifecycle notification, so playback and seeking do not require suspended JS.
@objc(IrgunBackgroundAudioPlugin)
public class IrgunBackgroundAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IrgunBackgroundAudioPlugin"
    public let jsName = "IrgunBackgroundAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "prepare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "beginBackground", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]
    public static weak var current: IrgunBackgroundAudioPlugin?
    private var player: AVPlayer?
    private var itemID = ""
    private var source = ""
    private var position: Double = 0
    private var updatedAt = Date()
    private var speed: Float = 1
    private var desiredPlaying = false
    private var pip = false
    private var active = false
    private var seeking = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var title = ""
    private var artist = ""
    public private(set) var backgroundSamples: [Double] = []

    override public func load() {
        Self.current = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.startBackground() })
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.active, let item = note.object as? AVPlayerItem, item === self.player?.currentItem else { return }
            self.desiredPlaying = false
            self.updateNowPlaying()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pauseNative() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.active else { return }
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue { self.player?.pause() }
            else if type == AVAudioSession.InterruptionType.ended.rawValue,
                    ((note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0,
                    self.desiredPlaying { self.activateSession(); self.player?.playImmediately(atRate: self.speed) }
        })
    }

    @objc public func prepare(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let id = call.getString("id") ?? ""
            let source = call.getString("url") ?? ""
            guard !id.isEmpty, let url = URL(string: source), url.scheme == "https" else { call.reject("Background media URL unavailable"); return }
            // Foreground bookkeeping cannot overwrite the native owner while
            // backgrounded, nor while it is handing its clock back to video.
            if self.active { call.resolve(self.snapshot()); return }
            let changed = id != self.itemID || source != self.source
            if changed {
                self.clearPlayer()
                self.itemID = id; self.source = source
                let player = AVPlayer(url: url)
                self.player = player
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    guard let self = self, self.active else { return }
                    self.updateNowPlaying()
                    if UIApplication.shared.applicationState == .background && player.timeControlStatus == .playing {
                        self.backgroundSamples.append(self.currentTime())
                        if self.backgroundSamples.count > 120 { self.backgroundSamples.removeFirst() }
                    }
                }
            }
            self.position = max(0, call.getDouble("position") ?? 0)
            self.updatedAt = Date()
            self.speed = Float(max(0.5, min(2, call.getDouble("rate") ?? 1)))
            self.desiredPlaying = call.getBool("playing") ?? false
            self.pip = call.getBool("pip") ?? false
            self.title = call.getString("title") ?? "Irgun Shiurai Torah"
            self.artist = call.getString("artist") ?? ""
            self.player?.isMuted = call.getBool("muted") ?? false
            self.player?.volume = Float(max(0, min(1, call.getDouble("volume") ?? 1)))
            if changed { self.player?.seek(to: CMTime(seconds:self.position, preferredTimescale:600)) }
            call.resolve(self.snapshot())
        }
    }

    @objc public func beginBackground(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.startBackground(); call.resolve(self.snapshot()) }
    }

    private func startBackground() {
        guard UIApplication.shared.applicationState != .active, !active, desiredPlaying, !pip, let player = player else { return }
        active = true
        backgroundSamples = []
        generation += 1
        let owner = generation
        let target = position + max(0, min(2, Date().timeIntervalSince(updatedAt))) * Double(speed)
        position = target; seeking = true
        activateSession()
        installRemoteCommands()
        // Native seeks continue after the WebView is suspended. Never start the
        // new source at 0 while waiting for a JavaScript seek callback.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, finished, self.generation == owner, self.active, self.desiredPlaying else { return }
                self.seeking = false
                self.activateSession()
                player.playImmediately(atRate: self.speed)
                self.updateNowPlaying()
            }
        }
    }

    private func activateSession() {
        do { let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .moviePlayback); try session.setActive(true) }
        catch { NSLog("Irgun background audio session failed: %@", String(describing: error)) }
    }

    @objc public func getState(_ call: CAPPluginCall) { DispatchQueue.main.async { call.resolve(self.snapshot()) } }
    @objc public func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let id = call.getString("id"), id != self.itemID { call.resolve(); return }
            let releaseToWebVideo = self.active && (call.getBool("releaseToWebVideo") ?? false)
            self.generation += 1; self.player?.pause(); self.active = false; self.seeking = false
            self.removeRemoteCommands()
            if call.getBool("clear") ?? false { self.desiredPlaying = false; self.clearPlayer(); self.itemID = ""; self.source = "" }
            if releaseToWebVideo {
                // The WebView owns its media session separately. Pause/dispose
                // native audio before allowing that interrupted owner to resume.
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                catch { NSLog("Irgun background session release failed: %@", String(describing: error)) }
                if let webView = self.bridge?.webView {
                    webView.setAllMediaPlaybackSuspended(false) {
                        webView.setNeedsLayout()
                        webView.layoutIfNeeded()
                        call.resolve()
                    }
                    return
                }
            }
            call.resolve()
        }
    }
    private func currentTime() -> Double { let value = player?.currentTime().seconds ?? position; return value.isFinite ? max(0, value) : position }
    public func snapshot() -> [String: Any] {
        ["id": itemID, "active": active, "playing": active && desiredPlaying,
         "advancing": player?.timeControlStatus == .playing, "position": active && !seeking ? currentTime() : position,
         "ready": player?.currentItem?.status == .readyToPlay, "failed": player?.currentItem?.status == .failed, "muted": player?.isMuted ?? false,
         "backgroundSamples": backgroundSamples]
    }
    private func pauseNative() { guard active else { return }; desiredPlaying = false; player?.pause(); updateNowPlaying() }
    private func updateNowPlaying() {
        guard active else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime(), MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 0]
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func installRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        func add(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true; remoteTargets.append((command, command.addTarget(handler: action)))
        }
        add(commands.pauseCommand) { [weak self] _ in self?.pauseNative(); return .success }
        add(commands.playCommand) { [weak self] _ in guard let self = self, self.active else { return .noSuchContent }; self.desiredPlaying = true; self.activateSession(); self.player?.playImmediately(atRate: self.speed); return .success }
        add(commands.skipForwardCommand) { [weak self] _ in self?.seekNative(by: 15); return .success }
        add(commands.skipBackwardCommand) { [weak self] _ in self?.seekNative(by: -15); return .success }
        add(commands.changePlaybackPositionCommand) { [weak self] event in guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; self?.player?.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600)); return .success }
    }
    private func seekNative(by delta: Double) { player?.seek(to: CMTime(seconds: max(0, currentTime() + delta), preferredTimescale: 600)) }
    private func removeRemoteCommands() { for (command, target) in remoteTargets { command.removeTarget(target) }; remoteTargets = [] }
    private func clearPlayer() {
        generation += 1
        player?.pause()
        if let timeObserver = timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil; active = false; removeRemoteCommands()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) }; clearPlayer() }
}
