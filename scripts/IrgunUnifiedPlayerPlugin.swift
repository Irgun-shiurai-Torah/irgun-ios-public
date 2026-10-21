import Foundation
import Capacitor
import AVFoundation
import AVKit
import CoreVideo
import MediaPlayer
import UIKit

// Android's Media3 timeline uses a thin track and a small round thumb.
// AVPlayer's preferredMaximumResolution is only a ceiling. For a manual
// resolution choice, offer exactly that height's original HLS variants instead.
// Retain the master playlist's AUDIO/SUBTITLES groups so audio does not vanish.
// There is no extra player, decoder, video control or user-facing diagnostics.
private final class IrgunFixedHLSManifest: NSObject, AVAssetResourceLoaderDelegate {
    private let body: Data
    private let assetURL: URL
    private static let sizePattern = try! NSRegularExpression(pattern: #"RESOLUTION=[0-9]+x([0-9]+)"#)
    private static let uriPattern = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)

    private static func height(of line: String) -> Int? {
        let ns = line as NSString
        guard let result = sizePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              result.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: result.range(at: 1)))
    }

    static func heights(in master: String) -> [Int] {
        let choices = master.components(separatedBy: .newlines).compactMap { line -> Int? in
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-STREAM-INF:") else { return nil }
            return height(of: line)
        }
        return Array(Set(choices)).sorted(by: >)
    }

    private static func rewriteAttributeURLs(_ line: String, relativeTo masterURL: URL) -> String {
        var rewritten = line
        let ns = line as NSString
        let matches = uriPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let original = ns.substring(with: match.range(at: 1))
            guard let address = URL(string: original, relativeTo: masterURL)?.absoluteURL,
                  ["http", "https"].contains(address.scheme?.lowercased() ?? "") else { continue }
            let replacement = #"URI=""# + address.absoluteString + #"""#
            rewritten = (rewritten as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return rewritten
    }

    static func filtered(_ master: String, from source: URL, height requiredHeight: Int) -> String? {
        guard master.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        var result: [String] = []
        var pendingStream: String?
        var selected = 0
        for rawLine in master.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingStream = line
                continue
            }
            if let header = pendingStream {
                if line.hasPrefix("#") { continue }
                if Self.height(of: header) == requiredHeight,
                   let uri = URL(string: line, relativeTo: source)?.absoluteURL,
                   uri.scheme?.lowercased() == "https" {
                    result.append(header)
                    result.append(uri.absoluteString)
                    selected += 1
                }
                pendingStream = nil
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                if Self.height(of: line) == requiredHeight {
                    result.append(rewriteAttributeURLs(line, relativeTo: source))
                }
            } else if line.hasPrefix("#") {
                result.append(rewriteAttributeURLs(line, relativeTo: source))
            }
        }
        guard selected > 0 else { return nil }
        return result.joined(separator: "\n") + "\n"
    }

    init?(master: String, source: URL, height: Int) {
        guard height > 0,
              let narrowed = Self.filtered(master, from: source, height: height),
              let content = narrowed.data(using: .utf8),
              var parts = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "irgunhls"
        var query = parts.queryItems ?? []
        query.append(URLQueryItem(name: "irgun_qa", value: String(height)))
        query.append(URLQueryItem(name: "irgun_session", value: UUID().uuidString))
        parts.queryItems = query
        guard let playlistURL = parts.url else { return nil }
        body = content
        assetURL = playlistURL
        super.init()
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme?.lowercased() == "irgunhls" else { return false }
        if let info = request.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(body.count)
            info.isByteRangeAccessSupported = true
        }
        if let transfer = request.dataRequest {
            let offset = max(0, Int(transfer.currentOffset))
            if offset < body.count {
                let remaining = body.count - offset
                let count = transfer.requestsAllDataToEndOfResource
                    ? remaining : min(remaining, max(0, transfer.requestedLength))
                if count > 0 {
                    transfer.respond(with: body.subdata(in: offset..<(offset + count)))
                }
            }
        }
        request.finishLoading()
        return true
    }
}

private final class IrgunTimelineSlider: UISlider {
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let track = super.trackRect(forBounds: bounds)
        return CGRect(x: track.minX, y: bounds.midY - 1, width: track.width, height: 2)
    }
}

// One native AVPlayer for ALL iOS lectures, including video, ordinary audio and
// protected owned audio. One AVPlayerItem survives Audio <-> Video for a shiur.
// Loading a different lecture replaces that item, never the AVPlayer instance.
// Audio mode preserves the item and clock (video HLS bandwidth is not guaranteed
// to drop). A single player layer supports inline, Mini, fullscreen and PiP.
@objc(IrgunUnifiedPlayerPlugin)
public final class IrgunUnifiedPlayerPlugin: CAPPlugin, CAPBridgedPlugin, AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate, UIPopoverPresentationControllerDelegate {
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
    private var controlsChrome: UIView?
    private var controlsVisible = false
    private var controlsHideTask: DispatchWorkItem?
    private var controlsHideDeadline: TimeInterval = 0
    private var controlsTouchActive = false
    private var controlsMenuOpen = false
    private var nativeIcons: [String: UIImage] = [:]
    private var nativePlay: UIButton?
    private var nativeQuality: UIButton?
    private var nativeSpeed: UIButton?
    private var nativeFull: UIButton?
    private var nativePiP: UIButton?
    private var nativeSeek: UISlider?
    private var nativeSeekTarget: Double?
    private var nativeElapsed: UILabel?
    private var nativeDuration: UILabel?
    private var fullscreenButtonTaps = 0
    private var qualityHeight: Int = 0
    private var availableHeights: [Int] = []
    private var qualityMaster: String?
    private var qualityMasterURL: URL?
    private var fixedQualityManifest: IrgunFixedHLSManifest?
    private var qualityChangeCount = 0
    private var qualityTimeout: DispatchWorkItem?
    private struct QualityChange {
        let serial: Int
        let targetHeight: Int
        let desiredPosition: Double
        let previousItem: AVPlayerItem
        let previousManifest: IrgunFixedHLSManifest?
        let targetManifest: IrgunFixedHLSManifest?
        let replacement: AVPlayerItem
        let finish: ((Bool) -> Void)?
        var isSeeking = false
    }
    private var qualityChange: QualityChange?
    private var isPiPRequested = false
    private var pipResumeWanted = false
    private var pipPausedByUser = false
    private var overlayOccluded = false
    #if targetEnvironment(simulator)
    private var simulatorControlTaps: [String: Int] = [:]
    private var simulatorFrameOutput: AVPlayerItemVideoOutput?
    private var simulatorFrameCount: Int = 0
    private var simulatorFrameTime: Double = 0
    private var simulatorLastFrameObserverRefreshAt: CFTimeInterval = 0
    private var simulatorLastDecodedFrameAt: CFTimeInterval = 0
    // Simulator-only evidence for actual native double-tap delivery and AVPlayer seeking.
    private var doubleTapSeekCount = 0
    private var doubleTapSeekOffset = 0.0
    private var doubleTapSeekFrom = 0.0
    private var doubleTapSeekTarget = 0.0
    private var doubleTapSeekAt: TimeInterval = 0
    private var doubleTapSeekCompleted = false
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
    private var playbackRecoveryTask: DispatchWorkItem?
    private var playbackWatchdogTask: DispatchWorkItem?
    private var playbackRecoveryAttempts = 0
    private var lastObservedPlaybackPosition: Double = 0
    private var lastPlaybackProgressAt = Date()
    private var lastPlaybackRecoveryAttemptAt = Date.distantPast
    private var lifecycleObservers: [NSObjectProtocol] = []
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
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.player.timeControlStatus == .playing {
                    self.playbackRecoveryTask?.cancel()
                    self.playbackRecoveryTask = nil
                    self.lastObservedPlaybackPosition = self.position()
                    self.lastPlaybackProgressAt = Date()
                } else {
                    self.schedulePlaybackRecoveryIfNeeded()
                }
                self.publishState()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.monitorPlaybackProgress()
            self.publishState()
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let item = notification.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.playingWanted = false
            self.publishState()
            // A real current-item completion drives same-folder audio advance.
            // Pause, buffering and layout changes must never look like EOF.
            self.notifyListeners("ended", data: self.snapshot())
        }
        // When the app goes Home, detach the video renderer, not the AVPlayerItem.
        // This allows the existing player to continue its audio track using the
        // background-audio entitlement. On return we reattach the same layer.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconcileBackgroundVideoLayer(isBackgrounded: true) })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconcileBackgroundVideoLayer(isBackgrounded: false) })
        // A periodic AVPlayer time observer can stop firing when an HLS item
        // stalls while timeControlStatus still says .playing. Keep a wall-clock
        // watchdog independent of media time so those stalls can recover.
        schedulePlaybackWatchdog()
    }

    private func schedulePlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.playbackWatchdogTask = nil
            self.monitorPlaybackProgress()
            self.schedulePlaybackWatchdog()
        }
        playbackWatchdogTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    private func reconcileBackgroundVideoLayer(isBackgrounded: Bool) {
        guard active else { return }
        if isBackgrounded {
            // Only the user's explicit PiP button may keep system PiP active.
            // On iPadOS, an automatic PiP transition can race didEnterBackground:
            // the controller may already report active before the WillStart
            // delegate's stop request has completed. Stop that unsolicited
            // session here too, instead of returning early and leaving the
            // inline player hidden when the app is reopened.
            guard !isPiPRequested else { return }
            if pipController?.isPictureInPictureActive == true {
                pipController?.stopPictureInPicture()
            }
            guard mode == "video" else { return }
            videoLayer.player = nil
            if playingWanted {
                do { try activateAudioSession() }
                catch { NSLog("Irgun background playback session unavailable: \\(error)") }
                // Do not replace the item or seek: the HLS audio track continues
                // at its existing clock without a second decoder/player.
                if player.rate < 0.01 { player.playImmediately(atRate: playbackRate) }
                schedulePlaybackRecoveryIfNeeded()
            }
        } else {
            if videoLayer.player == nil {
                videoLayer.player = player
                // Keep the existing decoded-frame output with the retained
                // item. Replacing it after backgrounding can freeze the new
                // output's timebase while the same AVPlayer keeps playing.
            }
            placeSurface(lastSurfaceRect)
            guard playingWanted else { return }
            if player.timeControlStatus != .playing {
                do { try activateAudioSession() }
                catch { NSLog("Irgun foreground playback session unavailable: \\(error)") }
                player.playImmediately(atRate: playbackRate)
                schedulePlaybackRecoveryIfNeeded()
            }
        }
    }

    private func monitorPlaybackProgress() {
        guard active, playingWanted, !controlsMenuOpen, nativeSeekTarget == nil,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let now = Date()
        let current = position()
        if current > lastObservedPlaybackPosition + 0.35 ||
           current < lastObservedPlaybackPosition - 1.0 {
            lastObservedPlaybackPosition = current
            lastPlaybackProgressAt = now
            playbackRecoveryAttempts = 0
            playbackRecoveryTask?.cancel()
            playbackRecoveryTask = nil
            return
        }
        if now.timeIntervalSince(lastPlaybackProgressAt) >= 5 {
            schedulePlaybackRecoveryIfNeeded()
        }
    }

    // AVPlayer can remain requested-to-play but stalled after an HLS gap or
    // lifecycle interruption. Retry only while the user's play intent remains
    // true. If reasserting play does not move the clock, seek the SAME item to
    // its current position to make AVFoundation rebuild the stalled read path.
    private func schedulePlaybackRecoveryIfNeeded() {
        guard active, playingWanted, !controlsMenuOpen, nativeSeekTarget == nil,
              let item = player.currentItem, item.status == .readyToPlay else {
            playbackRecoveryTask?.cancel()
            playbackRecoveryTask = nil
            return
        }
        guard playbackRecoveryTask == nil else { return }
        let expectedGeneration = generation
        let expectedItemEpoch = itemEpoch
        let expectedItem = item
        let expectedPosition = position()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.playbackRecoveryTask = nil
            guard self.active, self.playingWanted, !self.controlsMenuOpen,
                  self.nativeSeekTarget == nil,
                  self.generation == expectedGeneration,
                  self.itemEpoch == expectedItemEpoch,
                  self.player.currentItem === expectedItem,
                  self.player.currentItem?.status == .readyToPlay else { return }
            let current = self.position()
            if current > expectedPosition + 0.75 {
                self.lastObservedPlaybackPosition = current
                self.lastPlaybackProgressAt = Date()
                self.playbackRecoveryAttempts = 0
                return
            }
            let now = Date()
            guard now.timeIntervalSince(self.lastPlaybackRecoveryAttemptAt) >= 3 else {
                self.schedulePlaybackRecoveryIfNeeded()
                return
            }
            self.lastPlaybackRecoveryAttemptAt = now
            self.playbackRecoveryAttempts += 1
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("Irgun AVPlayer recovery could not reactivate audio session: \\(error)")
            }

            let verifyRecovery: (Double) -> Void = { [weak self] afterPosition in
                guard let self = self else { return }
                self.lastObservedPlaybackPosition = self.position()
                self.lastPlaybackProgressAt = Date()
                self.publishState()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self = self, self.active, self.playingWanted,
                          self.generation == expectedGeneration,
                          self.itemEpoch == expectedItemEpoch,
                          self.player.currentItem === expectedItem,
                          self.player.currentItem?.status == .readyToPlay else { return }
                    let latest = self.position()
                    if latest > afterPosition + 0.75 {
                        self.lastObservedPlaybackPosition = latest
                        self.lastPlaybackProgressAt = Date()
                        self.playbackRecoveryAttempts = 0
                        return
                    }
                    self.schedulePlaybackRecoveryIfNeeded()
                }
            }

            if self.playbackRecoveryAttempts % 2 == 0 {
                let target = CMTime(seconds: max(0, current), preferredTimescale: 600)
                self.player.seek(
                    to: target,
                    toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.active, self.playingWanted,
                              self.generation == expectedGeneration,
                              self.itemEpoch == expectedItemEpoch,
                              self.player.currentItem === expectedItem else { return }
                        self.player.playImmediately(atRate: self.playbackRate)
                        verifyRecovery(self.position())
                    }
                }
            } else {
                self.player.playImmediately(atRate: self.playbackRate)
                verifyRecovery(current)
            }
        }
        playbackRecoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
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
              let host = url.host?.lowercased() else { return nil }
        // Existing Drive/Irgun streams retain their current trust policy.
        if host == "api.irgunshiuraitorah.com" || host == "irgunshiuraitorah.com" ||
           host.hasSuffix(".irgunshiuraitorah.com") ||
           host.hasSuffix(".cloudflarestream.com") ||
           host.hasSuffix(".r2.dev") {
            return url
        }
        // Vimeo recorded-file URLs from the trusted API descriptor are signed
        // and redirect to Vimeo's own CDN. Reject iframe pages and lookalikes.
        guard url.user == nil && url.password == nil &&
              (url.port == nil || url.port == 443) && url.fragment == nil else { return nil }
        if host == "player.vimeo.com" {
            let path = url.path
            return path.hasPrefix("/play/") ||
                   path.hasPrefix("/progressive_redirect/") ||
                   path.hasPrefix("/external/") ? url : nil
        }
        if host.hasSuffix(".vimeocdn.com") { return url }
        return nil
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
        refreshControlsHideTimer()
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

    @discardableResult
    private func skip(seconds: Double, completion: ((Bool) -> Void)? = nil) -> (from: Double, target: Double) {
        let from = position()
        let target = max(0, from + seconds)
        #if targetEnvironment(simulator)
        if target < simulatorFrameTime - 2, let item = player.currentItem {
            simulatorLastFrameObserverRefreshAt = CACurrentMediaTime()
            attachSimulatedFrameOutput(to: item, resetStatistics: false)
        }
        #endif
        // Skip controls should land on the requested time, not the nearest HLS keyframe.
        // Explicit zero tolerances prevent a 15-second rewind from landing several seconds early.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { finished in
            if let completion = completion {
                DispatchQueue.main.async { completion(finished) }
            }
        }
        return (from, target)
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
        // After switching away from video, AVPlayerItemVideoOutput's host-time
        // mapping can remain behind the active AVPlayer clock. Check that
        // mapping first, then ask for real decoded pixels near the actual
        // current item time. Never advance counters from the clock alone.
        let hostNow = CACurrentMediaTime()
        let hostItemTime = output.itemTime(forHostTime: hostNow)
        let clockTime = position()
        // Only true AVPlayerItemVideoOutput pixel buffers count as frames.
        // Do not replace the output after a frame drought: AVFoundation can
        // freeze a replacement output's timebase on an already-playing item.
        // Keep the original output and query against the live item clock below.
        var candidates = [hostItemTime]
        if abs(hostItemTime.seconds - clockTime) > 1.2 {
            candidates.append(CMTime(seconds: max(0, clockTime - 0.15),
                                     preferredTimescale: 600))
        }
        for at in candidates where at.isValid && at.seconds.isFinite {
            guard output.hasNewPixelBuffer(forItemTime: at) else { continue }
            var displayed = CMTime.invalid
            guard output.copyPixelBuffer(forItemTime: at, itemTimeForDisplay: &displayed) != nil else { continue }
            let seconds = displayed.seconds.isFinite ? displayed.seconds : at.seconds
            if seconds.isFinite && seconds > simulatorFrameTime {
                simulatorFrameTime = seconds
                simulatorFrameCount += 1
                simulatorLastDecodedFrameAt = hostNow
                break
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
            "controlsVisible": controlsVisible && controlsAreAvailable,
            "fullscreenButtonTaps": fullscreenButtonTaps,
            "error": player.currentItem?.error?.localizedDescription ?? ""
        ]
        #if targetEnvironment(simulator)
        data["observedAt"] = Date().timeIntervalSince1970 * 1000
        data["controlTaps"] = simulatorControlTaps
        data["controlsMenuOpen"] = controlsMenuOpen
        data["decodedFrames"] = simulatorFrameCount
        data["frameTime"] = simulatorFrameTime
        data["controlsHideRemaining"] = max(0, controlsHideDeadline - ProcessInfo.processInfo.systemUptime)
        data["doubleTapCount"] = doubleTapSeekCount
        data["doubleTapOffset"] = doubleTapSeekOffset
        data["doubleTapFrom"] = doubleTapSeekFrom
        data["doubleTapTarget"] = doubleTapSeekTarget
        data["doubleTapAge"] = doubleTapSeekAt > 0 ? max(0, ProcessInfo.processInfo.systemUptime - doubleTapSeekAt) : 0
        data["doubleTapCompleted"] = doubleTapSeekCompleted
        // Observe real UIKit geometry for physical test taps. Accessibility
        // queries can outlast Media3's eight-second timeout on a large iPad
        // catalogue; these observations never reveal or activate a control.
        var buttons: [String: [String: Any]] = [:]
        func observeButtons(_ view: UIView) {
            if let button = view as? UIButton, let id = button.accessibilityIdentifier,
               let root = viewer.parent?.view {
                let rect = button.convert(button.bounds, to: root)
                let point = CGPoint(x: rect.midX, y: rect.midY)
                let hit = root.hitTest(point, with: nil)
                buttons[id] = ["x": Double(point.x), "y": Double(point.y),
                               "width": Double(rect.width), "height": Double(rect.height),
                               "hittable": controlsAreAvailable && controlsVisible && button.isEnabled &&
                                    (hit === button || hit?.isDescendant(of: button) == true)]
            }
            for child in view.subviews { observeButtons(child) }
        }
        if let chrome = controlsChrome { observeButtons(chrome) }
        data["buttons"] = buttons
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
        refreshControlsHideTimer()
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
            self.playbackRecoveryTask?.cancel()
            self.playbackRecoveryTask = nil
            self.playbackRecoveryAttempts = 0
            self.lastPlaybackRecoveryAttemptAt = .distantPast
            self.lastPlaybackProgressAt = Date()
            self.lastObservedPlaybackPosition = max(0, call.getDouble("position") ?? 0)
            self.lastSurfaceRect = call.getObject("rect")
            self.placeSurface(self.lastSurfaceRect)
            let replacing = self.itemID != id || self.itemURL != source ||
                            self.player.currentItem == nil
            self.generation += 1
            if replacing {
                self.clearPendingQualityChange()
                self.player.pause()
                self.itemObserver = nil
                let item = AVPlayerItem(url: url)
                #if targetEnvironment(simulator)
                self.attachSimulatedFrameOutput(to: item)
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
                self.nativeSeekTarget = nil
                self.availableHeights = []
                self.qualityMaster = nil
                self.qualityMasterURL = nil
                self.fixedQualityManifest = nil
                self.loadAvailableVariants(url)
            }
            self.active = true
            self.controlsTouchActive = false
            self.controlsMenuOpen = false
            // Match Android's unobstructed initial picture: only a real tap reveals controls.
            self.setControlsVisible(false)
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
            self.playbackRecoveryTask?.cancel()
            self.playbackRecoveryTask = nil
            self.playbackRecoveryAttempts = 0
            self.lastPlaybackRecoveryAttemptAt = .distantPast
            self.lastPlaybackProgressAt = Date()
            self.lastObservedPlaybackPosition = self.position()
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
            self.playbackRecoveryTask?.cancel()
            self.playbackRecoveryTask = nil
            self.player.pause()
            self.publishState()
            call.resolve(self.snapshot())
        }
    }

    @objc public func seek(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            let seconds = max(0, call.getDouble("position") ?? 0)
            self.nativeSeekTarget = nil
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
            let previousMode = self.mode
            self.mode = next
            // Make the native video surface visible BEFORE reconnecting the
            // layer. Replacing an AVPlayerItemVideoOutput in mid-playback can
            // leave its timebase frozen even while the audio clock advances;
            // keep the original output and the same AVPlayerItem instead.
            self.setControlsVisible(false)
            self.placeSurface(self.lastSurfaceRect)
            if next == "video" {
                let returningFromAudio = previousMode == "audio"
                if returningFromAudio || self.videoLayer.player == nil {
                    self.videoLayer.player = nil
                    self.videoLayer.player = self.player
                }
                if self.playingWanted {
                    self.lastObservedPlaybackPosition = self.position()
                    self.lastPlaybackProgressAt = Date()
                    self.playbackRecoveryAttempts = 0
                    self.player.playImmediately(atRate: self.playbackRate)
                    if returningFromAudio, let item = self.player.currentItem {
                        // A seek to the CURRENT clock (not to the beginning)
                        // asks AVFoundation to resume the video rendition that
                        // may have been suspended while only audio was visible.
                        // It never replaces the item or resets the shiur.
                        let expectedGeneration = self.generation
                        let expectedEpoch = self.itemEpoch
                        let at = CMTime(seconds: self.position(), preferredTimescale: 600)
                        self.player.seek(to: at,
                                         toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                                         toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] _ in
                            DispatchQueue.main.async {
                                guard let self = self, self.active, self.mode == "video",
                                      self.generation == expectedGeneration,
                                      self.itemEpoch == expectedEpoch,
                                      self.player.currentItem === item else { return }
                                if self.playingWanted {
                                    self.player.playImmediately(atRate: self.playbackRate)
                                }
                                self.publishState()
                            }
                        }
                    }
                }
            }
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
                self.setControlsVisible(false)
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
    private var controlsAreAvailable: Bool {
        active && mode == "video" && layout != "mini" && !overlayOccluded &&
        !viewer.view.isHidden && controlsOverlay?.isHidden == false &&
        !(pipController?.isPictureInPictureActive ?? false)
    }

    private func cancelControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
        controlsHideDeadline = 0
    }

    private func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        // Keep the transparent gesture surface alive when the chrome is hidden.
        // A tap must reveal controls without pausing or replacing the item.
        controlsChrome?.isHidden = !visible
        if !visible { cancelControlsHide() }
    }

    private func revealNativeControls() {
        cancelControlsHide()
        setControlsVisible(true)
        refreshControlsHideTimer()
    }

    private func refreshControlsHideTimer() {
        guard controlsAreAvailable else { cancelControlsHide(); return }
        // Playing and paused Video use the same eight-second inactivity timeout.
        // A user tap reveals controls; progress updates never extend that timeout.
        guard controlsVisible, !controlsTouchActive, !controlsMenuOpen else {
            cancelControlsHide()
            return
        }
        guard controlsHideTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.controlsHideTask = nil
            self.controlsHideDeadline = 0
            guard self.controlsAreAvailable,
                  !self.controlsTouchActive, !self.controlsMenuOpen else { return }
            self.setControlsVisible(false)
            self.publishState()
        }
        controlsHideTask = task
        controlsHideDeadline = ProcessInfo.processInfo.systemUptime + 8
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    @objc private func beginControlsTouch() {
        controlsTouchActive = true
        cancelControlsHide()
    }

    @objc private func endControlsTouch() {
        controlsTouchActive = false
        revealNativeControls()
    }

    @objc private func tapVideoSurface(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, controlsAreAvailable else { return }
        if controlsVisible { setControlsVisible(false) }
        else { revealNativeControls() }
        publishState()
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== controlsOverlay {
            if current is UIControl { return false }
            view = current.superview
        }
        // An in-flight double tap must not lose its touch target when the
        // eight-second playback chrome timeout hides the controls mid-gesture.
        // Button touches still belong to the buttons (guarded above).
        if let tap = gestureRecognizer as? UITapGestureRecognizer,
           tap.numberOfTapsRequired == 2, controlsAreAvailable {
            cancelControlsHide()
        }
        return true
    }

    // These paths are the Android app's irgun_*.xml vectors, drawn on the same
    // 24-unit canvas instead of substituting platform-dependent SF Symbols.
    private func androidControlImage(_ name: String) -> UIImage {
        if let image = nativeIcons[name] { return image }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            let path = UIBezierPath()
            func line(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.0, y: first.1))
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
                if close { path.close() }
            }
            switch name {
            case "pip":
                line([(3,5),(21,5),(21,19),(3,19)], close: true)
                line([(13,11),(19,11),(19,17),(13,17)], close: true)
            case "mini":
                line([(3,4),(21,4),(21,17),(3,17)], close: true)
                line([(8,19),(12,22),(16,19)])
            case "speed":
                path.append(UIBezierPath(ovalIn: CGRect(x: 3,y: 3,width: 18,height: 18)))
                line([(12,7),(12,12),(16,14)])
            case "shrink":
                line([(4,9),(9,9),(9,4)]); line([(20,9),(15,9),(15,4)])
                line([(15,20),(15,15),(20,15)]); line([(9,20),(9,15),(4,15)])
            default:
                line([(9,4),(4,4),(4,9)]); line([(15,4),(20,4),(20,9)])
                line([(20,15),(20,20),(15,20)]); line([(9,20),(4,20),(4,15)])
            }
            UIColor.white.setStroke()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }.withRenderingMode(.alwaysTemplate)
        nativeIcons[name] = image
        return image
    }

    // AndroidX Media3's exo_ic_{rewind,forward,play_circle_filled,
    // pause_circle_filled} vectors. See THIRD_PARTY_NOTICES.md.
    private func androidTransportImage(_ name: String) -> UIImage {
        if let image = nativeIcons[name] { return image }
        // Media3 fits play/pause into a 52pt target with 2pt padding; skip
        // artwork fills its 52pt background. Keep the amount text at 9pt.
        let size: CGFloat = name == "play" || name == "pause" ? 48 : 52
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: size / 24, y: size / 24)
            UIColor.white.setFill()
            if name == "play" || name == "pause" {
                let path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 20, height: 20))
                path.usesEvenOddFillRule = true
                if name == "pause" {
                    path.append(UIBezierPath(rect: CGRect(x: 9, y: 8, width: 2, height: 8)))
                    path.append(UIBezierPath(rect: CGRect(x: 13, y: 8, width: 2, height: 8)))
                } else {
                    path.move(to: CGPoint(x: 10, y: 7.5))
                    path.addLine(to: CGPoint(x: 16, y: 12))
                    path.addLine(to: CGPoint(x: 10, y: 16.5))
                    path.close()
                }
                path.fill()
            } else {
                context.saveGState()
                context.translateBy(x: 12, y: 12)
                context.scaleBy(x: name == "forward" ? -0.7 : 0.7, y: 0.7)
                context.translateBy(x: -12, y: -12)
                let p = UIBezierPath()
                p.move(to: CGPoint(x: 12, y: 5))
                p.addLine(to: CGPoint(x: 12, y: 1))
                p.addLine(to: CGPoint(x: 7, y: 6))
                p.addLine(to: CGPoint(x: 12, y: 11))
                p.addLine(to: CGPoint(x: 12, y: 7))
                p.addCurve(to: CGPoint(x: 18, y: 13), controlPoint1: CGPoint(x: 15.31, y: 7), controlPoint2: CGPoint(x: 18, y: 9.69))
                p.addCurve(to: CGPoint(x: 12, y: 19), controlPoint1: CGPoint(x: 18, y: 16.31), controlPoint2: CGPoint(x: 15.31, y: 19))
                p.addCurve(to: CGPoint(x: 6, y: 13), controlPoint1: CGPoint(x: 8.69, y: 19), controlPoint2: CGPoint(x: 6, y: 16.31))
                p.addLine(to: CGPoint(x: 4, y: 13))
                p.addCurve(to: CGPoint(x: 12, y: 21), controlPoint1: CGPoint(x: 4, y: 17.42), controlPoint2: CGPoint(x: 7.58, y: 21))
                p.addCurve(to: CGPoint(x: 20, y: 13), controlPoint1: CGPoint(x: 16.42, y: 21), controlPoint2: CGPoint(x: 20, y: 17.42))
                p.addCurve(to: CGPoint(x: 12, y: 5), controlPoint1: CGPoint(x: 20, y: 8.58), controlPoint2: CGPoint(x: 16.42, y: 5))
                p.close()
                p.fill()
                context.restoreGState()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                ("15" as NSString).draw(in: CGRect(x: 6, y: 10.5, width: 12, height: 7), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9 * 24 / size, weight: .bold),
                    .foregroundColor: UIColor.white, .paragraphStyle: paragraph
                ])
            }
        }.withRenderingMode(.alwaysOriginal)
        nativeIcons[name] = image
        return image
    }

    #if targetEnvironment(simulator)
    // Observations of actual UIKit delivery only; never activate a control or
    // extend its eight-second timeout on behalf of XCTest.
    @objc private func observeSimulatorControlTap(_ sender: UIButton) {
        guard let identifier = sender.accessibilityIdentifier else { return }
        simulatorControlTaps[identifier, default: 0] += 1
    }
    #endif

    private func button(_ text: String, width: CGFloat, height: CGFloat = 44, selector: Selector) -> UIButton {
        let result = UIButton(type: .system)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle(text, for: .normal)
        result.setTitleColor(.white, for: .normal)
        result.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        result.backgroundColor = .clear
        result.addTarget(self, action: selector, for: .touchUpInside)
        #if targetEnvironment(simulator)
        result.addTarget(self, action: #selector(observeSimulatorControlTap(_:)), for: .touchUpInside)
        #endif
        result.addTarget(self, action: #selector(beginControlsTouch), for: .touchDown)
        result.addTarget(self, action: #selector(endControlsTouch), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        result.widthAnchor.constraint(equalToConstant: width).isActive = true
        // Native iPad fullscreen controls need Apple's minimum 44pt hit target.
        // A 34pt button under the status-bar edge can be reported as hittable
        // by XCTest without UIKit receiving its touchUpInside action.
        result.heightAnchor.constraint(equalToConstant: height).isActive = true
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
        let chrome = UIView()
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.backgroundColor = UIColor(white: 0, alpha: 0.375)
        chrome.isHidden = true
        overlay.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: overlay.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
        ])
        controlsChrome = chrome

        let mini = button("⌄", width: 44, selector: #selector(tapMini))
        let pip = button("PiP", width: 44, selector: #selector(tapPiP))
        let quality = button("Auto", width: 72, selector: #selector(tapQuality))
        let speed = button("1×", width: 44, selector: #selector(tapSpeed))
        let full = button("⛶", width: 44, selector: #selector(tapFull))
        for (control, name) in [(mini, "mini"), (pip, "pip"), (speed, "speed")] {
            control.setImage(androidControlImage(name), for: .normal)
            control.setTitle(nil, for: .normal)
            control.tintColor = .white
        }
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
        // Match Android's full-width black toolbar and physical icon order.
        let top = UIStackView(arrangedSubviews: [UIView(),pip,quality,speed,full,mini])
        top.translatesAutoresizingMaskIntoConstraints = false
        top.axis = .horizontal
        top.semanticContentAttribute = .forceLeftToRight
        top.spacing = 0
        top.alignment = .center
        top.backgroundColor = UIColor(white: 0, alpha: 0.6)
        chrome.addSubview(top)
        NSLayoutConstraint.activate([
            // Never put the exit-fullscreen button inside the iPad status bar,
            // camera housing, or the iPhone dynamic island.
            top.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
            top.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            top.leadingAnchor.constraint(equalTo: overlay.leadingAnchor)
        ])

        let back = button("↶ 15", width: 52, height: 52, selector: #selector(tapBack))
        let play = button("▶", width: 52, height: 52, selector: #selector(tapPlay))
        let forward = button("15 ↷", width: 52, height: 52, selector: #selector(tapForward))
        back.setImage(androidTransportImage("back"), for: .normal)
        back.setTitle(nil, for: .normal)
        forward.setImage(androidTransportImage("forward"), for: .normal)
        forward.setTitle(nil, for: .normal)
        back.accessibilityIdentifier = "irgun-native-back-15"
        back.accessibilityLabel = "Back 15 seconds"
        play.accessibilityIdentifier = "irgun-native-play"
        forward.accessibilityIdentifier = "irgun-native-forward-15"
        forward.accessibilityLabel = "Forward 15 seconds"
        play.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        play.backgroundColor = .clear
        // button() already establishes the actual touch height. Do not
        // install a second conflicting height constraint on UIKit.
        nativePlay = play
        let center = UIStackView(arrangedSubviews: [back,play,forward])
        center.translatesAutoresizingMaskIntoConstraints = false
        center.axis = .horizontal
        center.semanticContentAttribute = .forceLeftToRight
        center.spacing = 10
        center.alignment = .center
        back.backgroundColor = .clear
        forward.backgroundColor = .clear
        chrome.addSubview(center)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 5),
            center.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -5)
        ])

        let seek = IrgunTimelineSlider()
        seek.translatesAutoresizingMaskIntoConstraints = false
        seek.minimumValue = 0
        seek.maximumValue = 1
        seek.minimumTrackTintColor = .white
        seek.maximumTrackTintColor = UIColor(white: 1, alpha: 0.55)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        seek.setThumbImage(thumb, for: .normal)
        seek.setThumbImage(thumb, for: .highlighted)
        seek.accessibilityIdentifier = "irgun-native-seek"
        seek.semanticContentAttribute = .forceLeftToRight
        seek.addTarget(self, action: #selector(beginControlsTouch), for: .touchDown)
        seek.addTarget(self, action: #selector(endControlsTouch), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        seek.addTarget(self, action: #selector(tapSeek), for: .touchUpInside)
        seek.addTarget(self, action: #selector(tapSeek), for: .touchUpOutside)
        // UISlider drag callbacks do not move the thumb when the track is tapped
        // on every iOS version. Add a non-cancelling tap while retaining drag.
        let seekTap = UITapGestureRecognizer(target: self, action: #selector(tapSeekTrack(_:)))
        seekTap.cancelsTouchesInView = false
        seek.addGestureRecognizer(seekTap)
        nativeSeek = seek

        func timeLabel() -> UILabel {
            let label=UILabel()
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
            label.textColor = .white
            label.text = "00:00"
            return label
        }
        let elapsed = timeLabel()
        let total = timeLabel()
        nativeElapsed = elapsed
        nativeDuration = total
        elapsed.textAlignment = .left
        total.textAlignment = .right
        let timeRow = UIStackView(arrangedSubviews: [elapsed, UIView(), total])
        timeRow.semanticContentAttribute = .forceLeftToRight
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal
        timeRow.distribution = .fill
        let bottom = UIStackView(arrangedSubviews: [seek,timeRow])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.axis = .vertical
        bottom.spacing = 1
        bottom.backgroundColor = UIColor(white: 0, alpha: 0.3)
        bottom.isLayoutMarginsRelativeArrangement = true
        bottom.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 4, right: 8)
        chrome.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor)
        ])

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(tapMini))
        swipe.direction = .down
        swipe.delegate = self
        viewer.view.addGestureRecognizer(swipe)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(tapDoubleSeek(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        viewer.view.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tapVideoSurface(_:)))
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: swipe)
        singleTap.delegate = self
        viewer.view.addGestureRecognizer(singleTap)
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
        nativePlay?.setImage(androidTransportImage(playingWanted ? "pause" : "play"), for: .normal)
        nativePlay?.setTitle(nil, for: .normal)
        nativePlay?.accessibilityLabel = playingWanted ? "Pause video" : "Play video"
        nativeFull?.accessibilityLabel = layout == "full" ? "Exit Fullscreen" : "Fullscreen"
        nativeQuality?.setTitle(qualityHeight > 0 ? "\(qualityHeight)p" : "Auto", for: .normal)
        nativeSpeed?.accessibilityValue = String(format: "%.2g×", Double(playbackRate))
        nativeFull?.setImage(androidControlImage(layout == "full" ? "shrink" : "fullscreen"), for: .normal)
        nativeFull?.setTitle(nil, for: .normal)
        nativeFull?.tintColor = .white
        let shownPosition = nativeSeekTarget ?? position()
        nativeElapsed?.text = formatTime(shownPosition)
        nativeDuration?.text = formatTime(duration())
        if let slider = nativeSeek, !slider.isTracking {
            slider.value = Float(duration() > 0 ? max(0,min(1,shownPosition / duration())) : 0)
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

    private func seekFromNativeSlider(_ fraction: Double) {
        guard active, duration() > 0 else { return }
        let clamped = max(0, min(1, fraction))
        let target = duration() * clamped
        nativeSeekTarget = target
        nativeSeek?.value = Float(clamped)
        nativeElapsed?.text = formatTime(target)
        let request = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == request else { return }
                // Earlier seeks may complete after the user has tapped again.
                guard self.nativeSeekTarget == target else { return }
                self.nativeSeekTarget = nil
                self.publishState()
            }
        }
    }

    @objc private func tapSeek() {
        guard let slider = nativeSeek else { return }
        seekFromNativeSlider(Double(slider.value))
    }

    @objc private func tapSeekTrack(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, active,
              let slider = nativeSeek, !slider.isTracking, duration() > 0 else { return }
        let track = slider.trackRect(forBounds: slider.bounds)
        guard track.width > 0 else { return }
        let x = gesture.location(in: slider).x
        seekFromNativeSlider(Double((x - track.minX) / track.width))
    }

    @objc private func tapDoubleSeek(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, controlsAreAvailable else { return }
        let point = recognizer.location(in: viewer.view)
        let w = viewer.view.bounds.width
        // Double-tap skipping is for the picture, never the progress bar.
        guard point.y > viewer.view.bounds.height * 0.16 &&
              point.y < viewer.view.bounds.height * 0.80 else { return }
        let offset: Double
        if point.x < w * 0.35 { offset = -15 }
        else if point.x > w * 0.65 { offset = 15 }
        else { return }
        #if targetEnvironment(simulator)
        doubleTapSeekCount += 1
        let event = doubleTapSeekCount
        doubleTapSeekCompleted = false
        let requested = skip(seconds: offset) { [weak self] finished in
            guard let self = self, self.doubleTapSeekCount == event else { return }
            self.doubleTapSeekCompleted = finished
        }
        doubleTapSeekOffset = offset
        doubleTapSeekFrom = requested.from
        doubleTapSeekTarget = requested.target
        doubleTapSeekAt = ProcessInfo.processInfo.systemUptime
        #else
        skip(seconds: offset)
        #endif
        revealNativeControls()
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
        revealNativeControls()
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
                self.resumeControlsAfterMenu()
                self.publishState()
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel) { [weak self] _ in self?.resumeControlsAfterMenu() })
        present(sheet, from:nativeSpeed)
    }

    @objc private func tapQuality() {
        guard active else { return }
        let sheet=UIAlertController(title:"Video quality",message:nil,preferredStyle:.actionSheet)
        let choices=[0]+availableHeights
        for height in choices {
            sheet.addAction(UIAlertAction(title:height==0 ? "Auto" : "\(height)p",style:.default) { [weak self] _ in
                self?.applyQuality(height)
                self?.resumeControlsAfterMenu()
            })
        }
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel) { [weak self] _ in self?.resumeControlsAfterMenu() })
        present(sheet, from:nativeQuality)
    }

    private func present(_ alert: UIAlertController, from button: UIButton?) {
        guard viewer.presentedViewController == nil else { return }
        controlsMenuOpen = true
        cancelControlsHide()
        if let pop = alert.popoverPresentationController {
            pop.sourceView = button ?? viewer.view
            pop.sourceRect = button?.bounds ?? CGRect(x:10,y:10,width:1,height:1)
            pop.delegate = self
        }
        viewer.present(alert,animated:true) { [weak self, weak alert] in alert?.presentationController?.delegate = self }
    }

    private func resumeControlsAfterMenu() {
        controlsMenuOpen = false
        revealNativeControls()
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        resumeControlsAfterMenu()
    }

    public func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        resumeControlsAfterMenu()
    }

    private func clearPendingQualityChange() {
        qualityChangeCount += 1
        qualityTimeout?.cancel()
        qualityTimeout = nil
        let pending = qualityChange
        qualityChange = nil
        pending?.finish?(false)
    }

    #if targetEnvironment(simulator)
    private func attachSimulatedFrameOutput(to item: AVPlayerItem,
                                            resetStatistics: Bool = true) {
        // The previous observer may have stopped delivering frames while the
        // same item continued playing audio. Remove it before reconnecting a
        // fresh AVPlayerItemVideoOutput; never fabricate a frame or advance a
        // test counter from player time alone.
        if let previous = simulatorFrameOutput,
           item.outputs.contains(where: { $0 === previous }) {
            item.remove(previous)
        }
        if resetStatistics { simulatorFrameCount = 0 }
        // A fresh output can legitimately resume at an EARLIER media time
        // after a user rewind. Keep the lifetime decoded-frame count, but
        // never hold the old rendition's future frameTime as a threshold.
        simulatorFrameTime = 0
        simulatorLastDecodedFrameAt = CACurrentMediaTime()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        simulatorFrameOutput = output
    }
    #endif

    private func restoreQualityAfterFailure(_ change: QualityChange) {
        guard qualityChange?.serial == change.serial else { return }
        clearPendingQualityChange()
        itemObserver = nil
        player.replaceCurrentItem(with: change.previousItem)
        fixedQualityManifest = change.previousManifest
        itemEpoch += 1
        #if targetEnvironment(simulator)
        attachSimulatedFrameOutput(to: change.previousItem)
        #endif
        itemObserver = change.previousItem.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.publishState() }
        }
        player.seek(to: CMTime(seconds: change.desiredPosition, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.active else { return }
                if self.playingWanted { self.player.playImmediately(atRate: self.playbackRate) }
                else { self.player.pause() }
                self.publishState()
            }
        }
    }

    private func finishQualityChangeIfReady() {
        guard var change = qualityChange,
              player.currentItem === change.replacement else { return }
        switch change.replacement.status {
        case .readyToPlay:
            guard !change.isSeeking else { return }
            change.isSeeking = true
            qualityChange = change
            let serial = change.serial
            player.seek(to: CMTime(seconds: change.desiredPosition, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)) { [weak self] completed in
                DispatchQueue.main.async {
                    guard let self = self, let waiting = self.qualityChange,
                          waiting.serial == serial else { return }
                    guard completed else { self.restoreQualityAfterFailure(waiting); return }
                    self.qualityTimeout?.cancel()
                    self.qualityTimeout = nil
                    self.qualityChange = nil
                    self.qualityHeight = waiting.targetHeight
                    self.fixedQualityManifest = waiting.targetManifest
                    if self.playingWanted { self.player.playImmediately(atRate: self.playbackRate) }
                    else { self.player.pause() }
                    self.publishState()
                    waiting.finish?(true)
                }
            }
        case .failed:
            restoreQualityAfterFailure(change)
        default:
            break
        }
    }

    private func applyQuality(_ height: Int, completion: ((Bool) -> Void)? = nil) {
        guard active, player.currentItem?.status == .readyToPlay,
              height == 0 || availableHeights.contains(height) else {
            completion?(false)
            return
        }
        if height == qualityHeight && qualityChange == nil {
            completion?(true)
            return
        }
        guard let oldItem = player.currentItem,
              let original = playableURL(itemURL),
              qualityChange == nil,
              !(pipController?.isPictureInPictureActive ?? false) else {
            completion?(false)
            return
        }
        let loader: IrgunFixedHLSManifest?
        let nextItem: AVPlayerItem
        if height == 0 {
            loader = nil
            nextItem = AVPlayerItem(url: original)
        } else {
            guard let master = qualityMaster, let masterURL = qualityMasterURL,
                  let narrowed = IrgunFixedHLSManifest(master: master, source: masterURL, height: height) else {
                completion?(false)
                return
            }
            loader = narrowed
            nextItem = AVPlayerItem(asset: narrowed.makeAsset())
        }
        qualityChangeCount += 1
        let serial = qualityChangeCount
        let previousPosition = position()
        let pending = QualityChange(serial: serial, targetHeight: height,
                                    desiredPosition: previousPosition,
                                    previousItem: oldItem, previousManifest: fixedQualityManifest,
                                    targetManifest: loader, replacement: nextItem,
                                    finish: completion)
        qualityChange = pending
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, let waiting = self.qualityChange,
                  waiting.serial == serial else { return }
            self.restoreQualityAfterFailure(waiting)
        }
        qualityTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        player.pause()
        itemObserver = nil
        player.replaceCurrentItem(with: nextItem)
        itemEpoch += 1
        #if targetEnvironment(simulator)
        attachSimulatedFrameOutput(to: nextItem)
        #endif
        itemObserver = nextItem.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.finishQualityChangeIfReady()
                self?.publishState()
            }
        }
        finishQualityChangeIfReady()
        publishState()
    }

    private func loadAvailableVariants(_ source: URL) {
        guard source.pathExtension.lowercased() == "m3u8" else { return }
        let owner = generation
        var request = URLRequest(url: source)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data = data, data.count < 1_048_576,
                  let status = (response as? HTTPURLResponse)?.statusCode,
                  (200...299).contains(status),
                  let manifest = String(data: data, encoding: .utf8),
                  manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return }
            let heights = IrgunFixedHLSManifest.heights(in: manifest)
            DispatchQueue.main.async {
                guard let self = self, self.generation == owner else { return }
                self.availableHeights = heights
                self.qualityMaster = manifest
                self.qualityMasterURL = response?.url ?? source
                self.updateNativeControls()
            }
        }.resume()
    }

    @objc public func setQuality(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.active else { call.reject("No native item loaded"); return }
            let height = max(0, call.getInt("height") ?? 0)
            guard height == 0 || self.availableHeights.contains(height) else {
                call.reject("Requested resolution was not advertised by this HLS stream")
                return
            }
            self.applyQuality(height) { succeeded in
                if succeeded { call.resolve(self.snapshot()) }
                else { call.reject("The selected HLS resolution could not be loaded; playback quality was restored") }
            }
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
        // Home should keep playing background audio, never create automatic PiP.
        // Only the explicit toolbar PiP button sets isPiPRequested.
        guard isPiPRequested else {
            pictureInPictureController.stopPictureInPicture()
            return
        }
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
        // Return to inline playback with controls hidden, matching initial video open.
        setControlsVisible(false)
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
            self.playbackRecoveryTask?.cancel()
            self.playbackRecoveryTask = nil
            self.playbackRecoveryAttempts = 0
            self.clearPendingQualityChange()
            self.qualityMaster = nil
            self.qualityMasterURL = nil
            self.fixedQualityManifest = nil
            self.qualityHeight = 0
            self.availableHeights = []
            self.cancelControlsHide()
            self.controlsTouchActive = false
            self.controlsMenuOpen = false
            self.setControlsVisible(false)
            if let pending = self.pendingOpen { pending.reject("Native media stopped") }
            self.pendingOpen = nil
            self.pendingOpenTimeout?.cancel()
            self.pendingOpenTimeout = nil
            self.pipResumeWanted = false
            self.pipPausedByUser = false
            self.playingWanted = false
            self.nativeSeekTarget = nil
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
        playbackWatchdogTask?.cancel()
        playbackRecoveryTask?.cancel()
        qualityTimeout?.cancel()
        pipController?.stopPictureInPicture()
        playerObserver = nil
        itemObserver = nil
        if let token = timeObserver { player.removeTimeObserver(token) }
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        pendingOpenTimeout?.cancel()
        controlsHideTask?.cancel()
        playbackRecoveryTask?.cancel()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        if let pending = pendingOpen { pending.reject("Native player released") }
        clearRemoteControls()
    }
}
