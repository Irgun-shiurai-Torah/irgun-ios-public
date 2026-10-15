import Foundation
import Capacitor
import AVFoundation
import AVKit
import MediaPlayer
import UIKit

// EXPERIMENTAL and opt-in. This plugin is never opened by production code unless
// the JavaScript native-player pilot flag is explicitly enabled. Do not register
// a second player for the same lecture in the normal app playback path.
//
// A single AVPlayerItem owns video and audio. Audio mode hides the native video
// surface without replacing the AVPlayerItem or seeking to an MP3. This preserves
// the clock and speed; it does NOT imply reduced mobile-video data consumption.
@objc(IrgunUnifiedPlayerPlugin)
public final class IrgunUnifiedPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IrgunUnifiedPlayerPlugin"
    public let jsName = "IrgunUnifiedPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    private let player = AVPlayer()
    private let viewer = AVPlayerViewController()
    private var itemID = ""
    private var itemURL = ""
    private var title = "Irgun Shiurai Torah"
    private var artist = ""
    private var active = false
    private var playingWanted = false
    private var playbackRate: Float = 1
    private var mode = "video"
    private var layout = "inline"
    private var lastSurfaceRect: [String: Any]?
    private var generation = 0
    private var itemEpoch = 0
    private var pendingOpen: CAPPluginCall?
    private var pendingOpenPosition: Double = 0
    private var pendingOpenGeneration: Int = 0
    private var pendingOpenTimeout: DispatchWorkItem?
    private var playerObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    override public func load() {
        viewer.player = player
        viewer.showsPlaybackControls = true
        viewer.allowsPictureInPicturePlayback = true
        viewer.entersFullScreenWhenPlaybackBegins = false
        viewer.exitsFullScreenWhenPlaybackEnds = false
        if #available(iOS 14.2, *) {
            // The pilot never surprises users by starting PiP merely on Home.
            // The system PiP button in AVPlayerViewController is supported.
            viewer.canStartPictureInPictureAutomaticallyFromInline = false
        }

        playerObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.publishState() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in self?.publishState() }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let item = notification.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.playingWanted = false
            self.publishState()
        }
    }

    private func playableURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "api.irgunshiuraitorah.com" || host == "irgunshiuraitorah.com" ||
              host.hasSuffix(".irgunshiuraitorah.com") else { return nil }
        return url
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
    }

    private func installViewer() -> Bool {
        if viewer.parent != nil { return true }
        guard let root = bridge?.webView?.window?.rootViewController else { return false }
        root.addChild(viewer)
        // An AVPlayerViewController surface should never resize across the WebView
        // title bar after iPad foreground/layout changes: frame is controlled by JS.
        viewer.view.autoresizingMask = []
        viewer.view.translatesAutoresizingMaskIntoConstraints = true
        viewer.view.clipsToBounds = true
        root.view.addSubview(viewer.view)
        viewer.didMove(toParent: root)
        return true
    }

    private func frame(from data: [String: Any]) -> CGRect? {
        guard let webView = bridge?.webView,
              let rootView = viewer.parent?.view else { return nil }
        func number(_ key: String) -> CGFloat {
            if let value = data[key] as? NSNumber { return CGFloat(truncating: value) }
            return 0
        }
        let rect = CGRect(x: number("x"), y: number("y"),
                          width: max(0, number("width")), height: max(0, number("height")))
        guard rect.width > 40 && rect.height > 30 else { return nil }
        return webView.convert(rect, to: rootView)
    }

    private func placeSurface(_ box: [String: Any]?) {
        if let box = box, let rect = frame(from: box), let root = viewer.parent?.view {
            // The fullscreen watch controls live above the WebView video stage.
            // Never let the native AVKit view overlap their tappable header
            // after foreground/rotation on iPad.
            let safeHeaderBottom = max(72, root.safeAreaInsets.top + 56)
            let top = max(safeHeaderBottom, rect.minY)
            let right = min(root.bounds.maxX, rect.maxX)
            let bottom = min(root.bounds.maxY, rect.maxY)
            let left = max(root.bounds.minX, rect.minX)
            viewer.view.frame = CGRect(x: left, y: top,
                                       width: max(0, right - left),
                                       height: max(0, bottom - top))
        } else if let root = viewer.parent?.view {
            let size = root.bounds.size
            let width = max(1, size.width)
            viewer.view.frame = CGRect(x: 0, y: max(90, (size.height - width * 9 / 16) / 3),
                                       width: width, height: width * 9 / 16)
        }
        viewer.view.isHidden = mode == "audio" || viewer.view.frame.width < 20 || viewer.view.frame.height < 20
        // In mini mode the WebView's overlay owns the mini controls and video hit target.
        viewer.view.isUserInteractionEnabled = mode == "video" && layout != "mini"
        viewer.view.setNeedsLayout()
    }

    private func installRemoteControls() {
        guard remoteTargets.isEmpty else { return }
        let controls = MPRemoteCommandCenter.shared()
        controls.skipForwardCommand.preferredIntervals = [15]
        controls.skipBackwardCommand.preferredIntervals = [15]
        func add(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget(handler: action)))
        }
        add(controls.playCommand) { [weak self] _ in
            guard let self = self, self.active else { return .noSuchContent }
            self.playingWanted = true
            try? self.activateAudioSession()
            self.player.playImmediately(atRate: self.playbackRate)
            return .success
        }
        add(controls.pauseCommand) { [weak self] _ in
            guard let self = self, self.active else { return .noSuchContent }
            self.playingWanted = false
            self.player.pause()
            return .success
        }
        add(controls.skipForwardCommand) { [weak self] _ in
            self?.skip(seconds: 15)
            return .success
        }
        add(controls.skipBackwardCommand) { [weak self] _ in
            self?.skip(seconds: -15)
            return .success
        }
    }

    private func skip(seconds: Double) {
        let target = max(0, (player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func clearRemoteControls() {
        for (command, token) in remoteTargets { command.removeTarget(token) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func position() -> Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func duration() -> Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func snapshot() -> [String: Any] {
        [
            "id": itemID,
            "active": active,
            "mode": mode,
            "layout": layout,
            "position": position(),
            "duration": duration(),
            "ready": player.currentItem?.status == .readyToPlay,
            "failed": player.currentItem?.status == .failed,
            "playing": active && player.timeControlStatus == .playing,
            "playRequested": playingWanted,
            "rate": Double(playbackRate),
            "sameItem": active && player.currentItem != nil,
            "itemEpoch": itemEpoch,
            "videoWidth": Double(player.currentItem?.presentationSize.width ?? 0),
            "videoHeight": Double(player.currentItem?.presentationSize.height ?? 0),
            "surfaceX": Double(viewer.view.frame.minX),
            "surfaceY": Double(viewer.view.frame.minY),
            "surfaceWidth": Double(viewer.view.frame.width),
            "surfaceHeight": Double(viewer.view.frame.height),
            "surfaceInteractive": viewer.view.isUserInteractionEnabled,
            "error": player.currentItem?.error?.localizedDescription ?? ""
        ]
    }

    private func publishState() {
        guard active else { return }
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position(),
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]
        let d = duration()
        if d > 0 { metadata[MPMediaItemPropertyPlaybackDuration] = d }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
        notifyListeners("state", data: snapshot())
    }

    // Resolve open only after AVFoundation knows whether the HLS media item is
    // playable. Otherwise WebKit shows a native player that immediately fails
    // while its JavaScript caller thinks the transition succeeded.
    private func finishPendingOpenIfReady() {
        guard let call = pendingOpen, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            pendingOpen = nil
            pendingOpenTimeout?.cancel()
            pendingOpenTimeout = nil
            let owner = pendingOpenGeneration
            let position = pendingOpenPosition
            let finish: () -> Void = {
                guard owner == self.generation, self.active else {
                    call.reject("Native media request was cancelled")
                    return
                }
                if self.playingWanted { self.player.playImmediately(atRate: self.playbackRate) }
                else { self.player.pause() }
                self.publishState()
                call.resolve(self.snapshot())
            }
            if position > 0.1 {
                player.seek(
                    to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600)
                ) { _ in DispatchQueue.main.async(execute: finish) }
            } else { finish() }
        case .failed:
            pendingOpen = nil
            pendingOpenTimeout?.cancel()
            pendingOpenTimeout = nil
            player.pause()
            active = false
            call.reject("Native media is not playable: " + (item.error?.localizedDescription ?? "unknown HLS error"))
        default:
            return
        }
    }

    private func waitForPlayableItem(_ call: CAPPluginCall, position: Double) {
        if let previous = pendingOpen {
            previous.reject("A new media request replaced this one")
        }
        pendingOpenTimeout?.cancel()
        pendingOpen = call
        pendingOpenPosition = position
        pendingOpenGeneration = generation
        let owner = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.pendingOpen != nil, self.pendingOpenGeneration == owner else { return }
            let waiting = self.pendingOpen
            self.pendingOpen = nil
            self.pendingOpenTimeout = nil
            self.player.pause()
            self.active = false
            waiting?.reject("Native HLS did not become playable within 25 seconds")
        }
        pendingOpenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        finishPendingOpenIfReady()
    }

    @objc public func open(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let id = call.getString("id"), !id.isEmpty,
                  let source = call.getString("url"),
                  let url = self.playableURL(source) else {
                call.reject("The native pilot requires an Irgun HTTPS HLS or MP4 URL")
                return
            }
            guard self.installViewer() else {
                call.reject("Native video surface is not ready")
                return
            }
            let mode = call.getString("mode") ?? "video"
            guard mode == "video" || mode == "audio" else {
                call.reject("Unsupported native playback mode")
                return
            }
            self.mode = mode
            self.layout = "inline"
            self.title = call.getString("title") ?? "Irgun Shiurai Torah"
            self.artist = call.getString("artist") ?? ""
            self.playbackRate = Float(max(0.5, min(2, call.getDouble("rate") ?? 1)))
            self.playingWanted = call.getBool("autoplay") ?? false
            self.lastSurfaceRect = call.getObject("rect")
            self.placeSurface(self.lastSurfaceRect)
            let replacing = self.itemID != id || self.itemURL != source ||
                            self.player.currentItem == nil
            self.generation += 1
            if replacing {
                self.player.pause()
                self.itemObserver = nil
                let item = AVPlayerItem(url: url)
                self.itemEpoch += 1
                self.player.replaceCurrentItem(with: item)
                self.itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.publishState()
                        self?.finishPendingOpenIfReady()
                    }
                }
                self.itemID = id
                self.itemURL = source
            }
            self.active = true
            self.installRemoteControls()
            do { try self.activateAudioSession() }
            catch { call.reject("Audio session unavailable: \(error.localizedDescription)"); return }
            let requested = max(0, call.getDouble("position") ?? 0)
            self.waitForPlayableItem(call, position: requested)
        }
    }

    @objc public func play(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            self.playingWanted = true
            do { try self.activateAudioSession() }
            catch { call.reject("Audio session unavailable: \(error.localizedDescription)"); return }
            self.player.playImmediately(atRate: self.playbackRate)
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func pause(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.playingWanted = false
            self.player.pause()
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func seek(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            let seconds = max(0, call.getDouble("position") ?? 0)
            let request = self.generation
            self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                DispatchQueue.main.async {
                    guard finished && request == self.generation else {
                        call.reject("Native seek was cancelled")
                        return
                    }
                    self.publishState()
                    call.resolve(self.snapshot())
                }
            }
        }
    }

    @objc public func setRate(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.playbackRate = Float(max(0.5, min(2, call.getDouble("rate") ?? 1)))
            if self.active && self.playingWanted {
                self.player.playImmediately(atRate: self.playbackRate)
            }
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func setMode(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            let next = call.getString("mode") ?? ""
            guard next == "audio" || next == "video" else {
                call.reject("Mode must be audio or video")
                return
            }
            // Critical single-owner property: do not replace or seek the item.
            self.mode = next
            self.placeSurface(self.lastSurfaceRect)
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func setLayout(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            let next = call.getString("layout") ?? "inline"
            guard ["inline", "mini", "full"].contains(next) else {
                call.reject("Unsupported native video layout")
                return
            }
            self.layout = next
            if let rect = call.getObject("rect") { self.lastSurfaceRect = rect }
            self.placeSurface(self.lastSurfaceRect)
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async { call.resolve(self.snapshot()) }
    }

    @objc public func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.generation += 1
            if let pending = self.pendingOpen { pending.reject("Native media stopped") }
            self.pendingOpen = nil
            self.pendingOpenTimeout?.cancel()
            self.pendingOpenTimeout = nil
            self.playingWanted = false
            self.player.pause()
            self.itemObserver = nil
            self.player.replaceCurrentItem(with: nil)
            self.active = false
            self.itemID = ""
            self.itemURL = ""
            self.mode = "video"
            self.layout = "inline"
            self.lastSurfaceRect = nil
            self.clearRemoteControls()
            if self.viewer.parent != nil {
                self.viewer.willMove(toParent: nil)
                self.viewer.view.removeFromSuperview()
                self.viewer.removeFromParent()
            }
            call.resolve(self.snapshot())
        }
    }

    deinit {
        playerObserver = nil
        itemObserver = nil
        if let token = timeObserver { player.removeTimeObserver(token) }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        pendingOpenTimeout?.cancel()
        if let pending = pendingOpen { pending.reject("Native player released") }
        clearRemoteControls()
    }
}
