import Foundation
import Capacitor
import AVFoundation
import AVKit
import CoreVideo
import MediaPlayer
import UIKit

// One native AVPlayer for ALL iOS lectures, including video, ordinary audio and
// protected owned audio. One AVPlayerItem survives Audio <-> Video for a shiur.
// Loading a different lecture replaces that item, never the AVPlayer instance.
// Audio mode preserves the item and clock (video HLS bandwidth is not guaranteed
// to drop). A single player layer supports inline, Mini, fullscreen and PiP.
@objc(IrgunUnifiedPlayerPlugin)
public final class IrgunUnifiedPlayerPlugin: CAPPlugin, CAPBridgedPlugin, AVPictureInPictureControllerDelegate {
    public static weak var current: IrgunUnifiedPlayerPlugin?
    public func simulatorSnapshot() -> [String: Any] { return snapshot() }
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
        CAPPluginMethod(name: "setQuality", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "enterPiP", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exitPiP", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setOverlayOccluded", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    private let player = AVPlayer()
    private let viewer = UIViewController()
    private let videoLayer = AVPlayerLayer()
    private var pipController: AVPictureInPictureController?
    private var controlsOverlay: UIView?
    private var nativePlay: UIButton?
    private var nativeQuality: UIButton?
    private var nativeSpeed: UIButton?
    private var nativeFull: UIButton?
    private var nativePiP: UIButton?
    private var nativeSeek: UISlider?
    private var nativeElapsed: UILabel?
    private var nativeDuration: UILabel?
    private var fullscreenButtonTaps = 0
    private var qualityHeight: Int = 0
    private var availableHeights: [Int] = []
    private var isPiPRequested = false
    private var pipResumeWanted = false
    private var pipPausedByUser = false
    private var overlayOccluded = false
    #if targetEnvironment(simulator)
    private var simulatorFrameOutput: AVPlayerItemVideoOutput?
    private var simulatorFrameCount: Int = 0
    private var simulatorFrameTime: Double = 0
    #endif
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
        Self.current = self
        viewer.view.backgroundColor = .black
        videoLayer.player = player
        // Home should continue audio without automatically opening system PiP.
        if #available(iOS 15.0, *) { player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible }
        videoLayer.videoGravity = .resizeAspect
        viewer.view.layer.addSublayer(videoLayer)
        installNativeControls()
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: videoLayer)
            pipController?.delegate = self
            if #available(iOS 14.2, *) {
                pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            }
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
        guard let url = URL(string: value) else { return nil }
        if url.isFileURL {
            // Only managed offline MP3 recordings in this app's sandbox.
            let path = url.standardizedFileURL.path
            let sandboxRoot=NSHomeDirectory()
            // Capacitor's Directory.Data uses Library/NoCloud on iOS.
            // Existing app versions may have saved data under another
            // sandbox data directory; never allow an arbitrary file URL.
            let allowedFolders=[
                sandboxRoot + "/Library/NoCloud/irgun-offline/",
                sandboxRoot + "/Library/Application Support/irgun-offline/",
                sandboxRoot + "/Documents/irgun-offline/"
            ]
            guard allowedFolders.contains(where: { path.hasPrefix($0) }),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return url.standardizedFileURL
        }
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "api.irgunshiuraitorah.com" || host == "irgunshiuraitorah.com" ||
              host.hasSuffix(".irgunshiuraitorah.com") ||
              host.hasSuffix(".cloudflarestream.com") ||
              host.hasSuffix(".r2.dev") else { return nil }
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
        if let root = viewer.parent?.view, layout == "full" {
            viewer.view.frame = root.bounds
        } else if let box = box, let rect = frame(from: box), let root = viewer.parent?.view {
            let safeHeaderBottom = max(72, root.safeAreaInsets.top + 56)
            let top = max(safeHeaderBottom, rect.minY)
            let right = min(root.bounds.maxX, rect.maxX)
            let bottom = min(root.bounds.maxY, rect.maxY)
            let left = max(root.bounds.minX, rect.minX)
            viewer.view.frame = CGRect(x: left, y: top,
                                       width: max(0, right - left),
                                       height: max(0, bottom - top))
        } else {
            viewer.view.frame = .zero
        }
        videoLayer.frame = viewer.view.bounds
        controlsOverlay?.frame = viewer.view.bounds
        viewer.view.isHidden = mode == "audio" || overlayOccluded || viewer.view.frame.width < 20 || viewer.view.frame.height < 20
        // Mini video is visible but does not steal taps from the WebView's bar.
        viewer.view.isUserInteractionEnabled = mode == "video" && layout != "mini" && !overlayOccluded && !(pipController?.isPictureInPictureActive ?? false)
        controlsOverlay?.isHidden = mode != "video" || layout == "mini" || overlayOccluded || (pipController?.isPictureInPictureActive ?? false)
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
            if self.isPiPRequested { self.pipPausedByUser = false; self.pipResumeWanted = true }
            self.playingWanted = true
            try? self.activateAudioSession()
            self.player.playImmediately(atRate: self.playbackRate)
            return .success
        }
        add(controls.pauseCommand) { [weak self] _ in
            guard let self = self, self.active else { return .noSuchContent }
            // An explicit background remote pause must survive PiP teardown;
            // iOS also issues system pauses while returning to the foreground.
            if self.isPiPRequested && UIApplication.shared.applicationState == .background {
                self.pipPausedByUser = true
            }
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

    #if targetEnvironment(simulator)
    private func inspectDecodedVideoFrame() {
        guard let output = simulatorFrameOutput, active, mode == "video" else { return }
        let at = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: at) else { return }
        var displayed = CMTime.invalid
        if output.copyPixelBuffer(forItemTime: at, itemTimeForDisplay: &displayed) != nil {
            let seconds = displayed.seconds.isFinite ? displayed.seconds : at.seconds
            if seconds.isFinite, seconds > simulatorFrameTime {
                simulatorFrameTime = seconds
                simulatorFrameCount += 1
            }
        }
    }
    #endif

    private func snapshot() -> [String: Any] {
        #if targetEnvironment(simulator)
        inspectDecodedVideoFrame()
        #endif
        var data: [String: Any] = [
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
            "qualityHeight": qualityHeight,
            "qualities": availableHeights,
            "pipActive": pipController?.isPictureInPictureActive ?? false,
            "pipSupported": AVPictureInPictureController.isPictureInPictureSupported(),
            "pipPossible": pipController?.isPictureInPicturePossible ?? false,
            "layerReady": videoLayer.isReadyForDisplay && !viewer.view.isHidden,
            "overlayOccluded": overlayOccluded,
            "pipRequested": isPiPRequested,
            "videoWidth": Double(player.currentItem?.presentationSize.width ?? 0),
            "videoHeight": Double(player.currentItem?.presentationSize.height ?? 0),
            "surfaceX": Double(viewer.view.frame.minX),
            "surfaceY": Double(viewer.view.frame.minY),
            "surfaceWidth": Double(viewer.view.frame.width),
            "surfaceHeight": Double(viewer.view.frame.height),
            "surfaceInteractive": viewer.view.isUserInteractionEnabled,
            "fullscreenButtonTaps": fullscreenButtonTaps,
            "error": player.currentItem?.error?.localizedDescription ?? ""
        ]
        #if targetEnvironment(simulator)
        data["decodedFrames"] = simulatorFrameCount
        data["frameTime"] = simulatorFrameTime
        #endif
        return data
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
        updateNativeControls()
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
                #if targetEnvironment(simulator)
                self.simulatorFrameCount = 0
                self.simulatorFrameTime = 0
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ])
                item.add(output)
                self.simulatorFrameOutput = output
                #endif
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
                self.qualityHeight = 0
                self.availableHeights = []
                self.loadAvailableVariants(url)
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
            if self.isPiPRequested { self.pipPausedByUser = false; self.pipResumeWanted = true }
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
            if self.isPiPRequested { self.pipPausedByUser = true }
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
            if next == "audio", self.pipController?.isPictureInPictureActive == true {
                self.pipController?.stopPictureInPicture()
            }
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
            if next == "mini" {
                if self.pipController?.isPictureInPictureActive == true {
                    self.pipController?.stopPictureInPicture()
                }
                self.isPiPRequested = false
                self.notifyListeners("pipState", data:["active":false,"reason":"mini"])
            }
            self.layout = next
            if let rect = call.getObject("rect") { self.lastSurfaceRect = rect }
            self.placeSurface(self.lastSurfaceRect)
            self.publishState()
            call.resolve(self.snapshot())
        }
    }


    // Native controls modeled after the Android Media3 layout. Each control
    // manipulates this AVPlayer only; these are not WebKit media commands.
    private func button(_ text: String, width: CGFloat, selector: Selector) -> UIButton {
        let result = UIButton(type: .system)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle(text, for: .normal)
        result.setTitleColor(.white, for: .normal)
        result.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        result.backgroundColor = UIColor(red: 0.055, green: 0.11, blue: 0.18, alpha: 0.86)
        result.layer.cornerRadius = 10
        result.addTarget(self, action: selector, for: .touchUpInside)
        result.widthAnchor.constraint(equalToConstant: width).isActive = true
        // Native iPad fullscreen controls need Apple's minimum 44pt hit target.
        // A 34pt button under the status-bar edge can be reported as hittable
        // by XCTest without UIKit receiving its touchUpInside action.
        result.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return result
    }

    private func installNativeControls() {
        guard controlsOverlay == nil else { return }
        let overlay = UIView(frame: viewer.view.bounds)
        overlay.backgroundColor = .clear
        overlay.translatesAutoresizingMaskIntoConstraints = false
        viewer.view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: viewer.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: viewer.view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: viewer.view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: viewer.view.bottomAnchor)
        ])
        controlsOverlay = overlay

        let mini = button("⌄", width: 32, selector: #selector(tapMini))
        let pip = button("PiP", width: 40, selector: #selector(tapPiP))
        let quality = button("Auto", width: 58, selector: #selector(tapQuality))
        let speed = button("1×", width: 52, selector: #selector(tapSpeed))
        let full = button("⛶", width: 44, selector: #selector(tapFull))
        mini.accessibilityIdentifier = "irgun-native-mini"
        mini.accessibilityLabel = "Keep playing at bottom of app"
        pip.accessibilityIdentifier = "irgun-native-pip"
        pip.accessibilityLabel = "Picture in Picture"
        quality.accessibilityIdentifier = "irgun-native-quality"
        quality.accessibilityLabel = "Video quality"
        speed.accessibilityIdentifier = "irgun-native-speed"
        speed.accessibilityLabel = "Playback speed"
        full.accessibilityIdentifier = "irgun-native-fullscreen"
        nativeQuality = quality
        nativeSpeed = speed
        nativeFull = full
        nativePiP = pip
        let top = UIStackView(arrangedSubviews: [mini,pip,quality,speed,full])
        top.translatesAutoresizingMaskIntoConstraints = false
        top.axis = .horizontal
        top.spacing = 5
        top.alignment = .center
        overlay.addSubview(top)
        NSLayoutConstraint.activate([
            // Never put the exit-fullscreen button inside the iPad status bar,
            // camera housing, or the iPhone dynamic island.
            top.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 7),
            top.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -6),
            top.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 4)
        ])

        let back = button("↶ 15", width: 46, selector: #selector(tapBack))
        let play = button("▶", width: 52, selector: #selector(tapPlay))
        let forward = button("15 ↷", width: 46, selector: #selector(tapForward))
        back.accessibilityIdentifier = "irgun-native-back-15"
        back.accessibilityLabel = "Back 15 seconds"
        play.accessibilityIdentifier = "irgun-native-play"
        forward.accessibilityIdentifier = "irgun-native-forward-15"
        forward.accessibilityLabel = "Forward 15 seconds"
        play.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        play.layer.cornerRadius = 17
        // button() already establishes the actual touch height. Do not
        // install a second conflicting height constraint on UIKit.
        nativePlay = play
        let center = UIStackView(arrangedSubviews: [back,play,forward])
        center.translatesAutoresizingMaskIntoConstraints = false
        center.axis = .horizontal
        center.spacing = 22
        center.alignment = .center
        overlay.addSubview(center)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 5),
            center.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -5)
        ])

        let seek = UISlider()
        seek.translatesAutoresizingMaskIntoConstraints = false
        seek.minimumValue = 0
        seek.maximumValue = 1
        seek.minimumTrackTintColor = UIColor(red: 0.82, green: 0.69, blue: 0.42, alpha: 1)
        seek.maximumTrackTintColor = UIColor(white: 1, alpha: 0.55)
        seek.addTarget(self, action: #selector(tapSeek), for: .touchUpInside)
        seek.addTarget(self, action: #selector(tapSeek), for: .touchUpOutside)
        nativeSeek = seek

        func timeLabel() -> UILabel {
            let label=UILabel()
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.text = "00:00"
            return label
        }
        let elapsed = timeLabel()
        let total = timeLabel()
        nativeElapsed = elapsed
        nativeDuration = total
        total.textAlignment = .right
        let timeRow = UIStackView(arrangedSubviews: [elapsed, UIView(), total])
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal
        timeRow.distribution = .fill
        let bottom = UIStackView(arrangedSubviews: [seek,timeRow])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.axis = .vertical
        bottom.spacing = 0
        overlay.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 9),
            bottom.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -9),
            bottom.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -5)
        ])

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(tapMini))
        swipe.direction = .down
        overlay.addGestureRecognizer(swipe)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(tapDoubleSeek(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        overlay.addGestureRecognizer(doubleTap)
        updateNativeControls()
    }

    private func formatTime(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func updateNativeControls() {
        nativePlay?.setTitle(playingWanted ? "Ⅱ" : "▶", for: .normal)
        nativePlay?.accessibilityLabel = playingWanted ? "Pause video" : "Play video"
        nativeFull?.accessibilityLabel = layout == "full" ? "Exit Fullscreen" : "Fullscreen"
        nativeQuality?.setTitle(qualityHeight > 0 ? "\(qualityHeight)p" : "Auto", for: .normal)
        nativeSpeed?.setTitle(String(format: "%.2g×", Double(playbackRate)), for: .normal)
        nativeFull?.setTitle(layout == "full" ? "↙" : "⛶", for: .normal)
        nativeElapsed?.text = formatTime(position())
        nativeDuration?.text = formatTime(duration())
        if let slider = nativeSeek, !slider.isTracking {
            slider.value = Float(duration() > 0 ? max(0,min(1,position() / duration())) : 0)
            slider.isEnabled = duration() > 0
        }
        nativePiP?.isEnabled = AVPictureInPictureController.isPictureInPictureSupported()
        nativePiP?.alpha = AVPictureInPictureController.isPictureInPictureSupported() ? 1 : 0.4
    }

    @objc private func tapPlay() {
        guard active else { return }
        playingWanted.toggle()
        if playingWanted {
            try? activateAudioSession()
            player.playImmediately(atRate: playbackRate)
        } else {
            player.pause()
        }
        publishState()
    }

    @objc private func tapBack() { skip(seconds: -15); publishState() }
    @objc private func tapForward() { skip(seconds: 15); publishState() }

    @objc private func tapSeek() {
        guard active, let slider = nativeSeek, duration() > 0 else { return }
        let target = duration() * Double(slider.value)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        publishState()
    }

    @objc private func tapDoubleSeek(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: viewer.view)
        let w = viewer.view.bounds.width
        if point.x < w * 0.35 { skip(seconds: -15) }
        else if point.x > w * 0.65 { skip(seconds: 15) }
        else { return }
        publishState()
    }

    @objc private func tapMini() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
            isPiPRequested = false
        }
        if layout == "full" {
            layout = "inline"
            placeSurface(lastSurfaceRect)
            notifyListeners("requestFullscreen", data: ["fullscreen": false])
        }
        notifyListeners("requestMinimize", data: [:])
    }

    @objc private func tapFull() {
        fullscreenButtonTaps += 1
        layout = layout == "full" ? "inline" : "full"
        placeSurface(lastSurfaceRect)
        notifyListeners("requestFullscreen", data: ["fullscreen": layout == "full"])
        publishState()
    }

    private func rememberPiPPlaybackIntent() {
        pipResumeWanted = playingWanted && player.timeControlStatus == .playing
        pipPausedByUser = false
    }

    @objc private func tapPiP() {
        guard active, mode == "video", let pip = pipController else { return }
        if pip.isPictureInPicturePossible {
            rememberPiPPlaybackIntent()
            isPiPRequested = true
            pip.startPictureInPicture()
            publishState()
        } else {
            notifyListeners("pipUnavailable", data: ["message": "Picture in Picture is not ready"])
        }
    }

    @objc private func tapSpeed() {
        guard active else { return }
        let sheet=UIAlertController(title: "Playback speed", message: nil, preferredStyle: .actionSheet)
        for value in [0.75,1,1.25,1.5,1.75,2] as [Double] {
            let name=String(format:"%.2g×",value)
            sheet.addAction(UIAlertAction(title:name,style:.default) { [weak self] _ in
                guard let self = self else { return }
                self.playbackRate = Float(value)
                if self.playingWanted { self.player.playImmediately(atRate: self.playbackRate) }
                self.publishState()
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        present(sheet, from:nativeSpeed)
    }

    @objc private func tapQuality() {
        guard active else { return }
        let sheet=UIAlertController(title:"Video quality",message:nil,preferredStyle:.actionSheet)
        let choices=[0]+availableHeights
        for height in choices {
            sheet.addAction(UIAlertAction(title:height==0 ? "Auto" : "\(height)p",style:.default) { [weak self] _ in
                self?.applyQuality(height)
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        present(sheet, from:nativeQuality)
    }

    private func present(_ alert: UIAlertController, from button: UIButton?) {
        guard viewer.presentedViewController == nil else { return }
        if let pop = alert.popoverPresentationController {
            pop.sourceView = button ?? viewer.view
            pop.sourceRect = button?.bounds ?? CGRect(x:10,y:10,width:1,height:1)
        }
        viewer.present(alert,animated:true)
    }

    private func applyQuality(_ height: Int) {
        guard height == 0 || availableHeights.contains(height) else { return }
        qualityHeight=height
        // ABR remains Apple's; the cap limits the variant without replacing
        // the AVPlayerItem, changing clock or creating a second decoder.
        if height == 0 { player.currentItem?.preferredMaximumResolution = .zero }
        else { player.currentItem?.preferredMaximumResolution = CGSize(width: CGFloat(height) * 16 / 9, height: CGFloat(height)) }
        publishState()
    }

    private func loadAvailableVariants(_ source: URL) {
        guard source.pathExtension.lowercased() == "m3u8" else { return }
        let owner=generation
        var request=URLRequest(url:source)
        request.timeoutInterval=8
        URLSession.shared.dataTask(with:request) { [weak self] data,_,_ in
            guard let data = data, let manifest=String(data:data,encoding:.utf8),
                  let regex=try? NSRegularExpression(pattern:"RESOLUTION=[0-9]+x([0-9]+)") else { return }
            let ns=manifest as NSString
            let matches=regex.matches(in:manifest,range:NSRange(location:0,length:ns.length))
            let heights=Array(Set(matches.compactMap { match -> Int? in
                guard match.numberOfRanges > 1 else { return nil }
                return Int(ns.substring(with:match.range(at:1)))
            })).sorted(by:>)
            DispatchQueue.main.async {
                guard let self = self, self.generation == owner else { return }
                self.availableHeights=heights
                self.updateNativeControls()
            }
        }.resume()
    }

    @objc public func setQuality(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded");return }
            let height=max(0,call.getInt("height") ?? 0)
            guard height == 0 || self.availableHeights.contains(height) else {
                call.reject("Requested video quality was not advertised by this HLS stream");return
            }
            self.applyQuality(height)
            call.resolve(self.snapshot())
        }
    }

    @objc public func enterPiP(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active, self.mode == "video",
                  let pip=self.pipController,
                  pip.isPictureInPicturePossible else {
                call.reject("System Picture in Picture is not ready");return
            }
            self.rememberPiPPlaybackIntent()
            self.isPiPRequested=true
            pip.startPictureInPicture()
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func exitPiP(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if self.pipController?.isPictureInPictureActive == true {
                self.pipController?.stopPictureInPicture()
            }
            self.isPiPRequested = false
            self.placeSurface(self.lastSurfaceRect)
            call.resolve(self.snapshot())
        }
    }

    @objc public func setOverlayOccluded(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.overlayOccluded = call.getBool("occluded") ?? false
            self.placeSurface(self.lastSurfaceRect)
            call.resolve(self.snapshot())
        }
    }

    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPRequested = true
        placeSurface(lastSurfaceRect)
    }
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if !isPiPRequested || layout == "mini" || mode != "video" || !active {
            pictureInPictureController.stopPictureInPicture()
            isPiPRequested = false
            notifyListeners("pipState", data:["active":false,"reason":"mini"])
            return
        }
        isPiPRequested = true
        notifyListeners("pipState", data:["active":true])
        placeSurface(lastSurfaceRect)
        publishState()
    }
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let shouldResume = pipResumeWanted && !pipPausedByUser && active && mode == "video"
        pipResumeWanted = false
        pipPausedByUser = false
        isPiPRequested = false
        placeSurface(lastSurfaceRect)
        // AVKit may pause while leaving system PiP. Resume the SAME AVPlayerItem
        // only when video had been playing and no explicit pause was requested.
        if shouldResume {
            playingWanted = true
            try? activateAudioSession()
            player.playImmediately(atRate: playbackRate)
        }
        notifyListeners("pipState", data:["active":false])
        publishState()
    }
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        pipResumeWanted = false
        pipPausedByUser = false
        isPiPRequested = false
        notifyListeners("pipState", data:["active":false])
        notifyListeners("pipUnavailable", data:["message":error.localizedDescription])
        placeSurface(lastSurfaceRect)
        publishState()
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
            self.pipResumeWanted = false
            self.pipPausedByUser = false
            self.playingWanted = false
            self.player.pause()
            #if targetEnvironment(simulator)
            self.simulatorFrameOutput = nil
            self.simulatorFrameCount = 0
            self.simulatorFrameTime = 0
            #endif
            self.pipController?.stopPictureInPicture()
            self.isPiPRequested = false
            self.overlayOccluded = false
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
        pipController?.stopPictureInPicture()
        playerObserver = nil
        itemObserver = nil
        if let token = timeObserver { player.removeTimeObserver(token) }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        pendingOpenTimeout?.cancel()
        if let pending = pendingOpen { pending.reject("Native player released") }
        clearRemoteControls()
    }
}
