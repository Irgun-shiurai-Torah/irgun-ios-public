import XCTest
import Network

final class PlaybackUITests: XCTestCase {
    private var app: XCUIApplication!
    private enum Failure: Error { case timedOut(String) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.irgunshiuraitorah.app")
        app.launchArguments = ["--irgun-simulator-tests"]
        if name.contains("testReportedShiurDirectPlaybackAndUnlistedEmbed") {
            app.launchArguments.append("--irgun-reported-mp4")
        }
        app.launch()
        _ = try waitFor("Library must load from the API", timeout: 90) {
            ($0["libraryReady"] as? Bool == true) && self.number($0, "libraryCount") > 0
        }
    }

    override func tearDownWithError() throws {
        evidence("final-state")
        app?.terminate()
    }

    private func snapshot() -> [String: Any] {
        let connection = NWConnection(host: "127.0.0.1", port: 47291, using: .tcp)
        let queue = DispatchQueue(label: "org.irgun.tests.observation")
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var payload = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                lock.lock()
                if let data = data { payload.append(data) }
                let done = payload.contains(10) || complete || error != nil
                lock.unlock()
                if done { finished.signal() } else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: receive()
            case .failed: finished.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        let completed = finished.wait(timeout: .now() + 3) == .success
        connection.stateUpdateHandler = nil
        connection.cancel()
        lock.lock(); let data = payload; lock.unlock()
        guard completed, let object = try? JSONSerialization.jsonObject(with: data),
              let result = object as? [String: Any] else { return [:] }
        return result
    }

    private func number(_ state: [String: Any], _ key: String) -> Double {
        (state[key] as? NSNumber)?.doubleValue ?? 0
    }

    @discardableResult
    private func waitFor(_ message: String, timeout: TimeInterval = 40,
                         condition: @escaping ([String: Any]) -> Bool) throws -> [String: Any] {
        let predicate = NSPredicate { _, _ in condition(self.snapshot()) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        if XCTWaiter.wait(for: [expectation], timeout: timeout) != .completed {
            evidence("failure-\(message)")
            XCTFail("\(message). Last state: \(snapshot())")
            throw Failure.timedOut(message)
        }
        return snapshot()
    }

    private func evidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys]) {
            let state = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            state.name = "\(name)-playback.json"
            state.lifetime = .keepAlways
            add(state)
        }
    }

    private func tapWebButton(_ label: String) throws {
        let hide = app.buttons["ist-simulator-hide-controls"]
        if hide.exists && hide.isHittable { hide.tap() }
        // UI-only actions: native UIKit controls for the one AVPlayer, web
        // controls only for the legacy non-native regression scenario.
        let native = snapshot()["nativePlayer"] as? [String: Any] ?? [:]
        if native["active"] as? Bool == true && native["mode"] as? String == "video" {
            let mappings = [
                "Fullscreen": "irgun-native-fullscreen",
                "Exit Fullscreen": "irgun-native-fullscreen",
                "Pause video": "irgun-native-play",
                "Play video": "irgun-native-play",
                "Picture in Picture": "irgun-native-pip"
            ]
            if let identifier = mappings[label] {
                let control = app.buttons[identifier]
                let ready = NSPredicate(format:"exists == true AND hittable == true")
                guard XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:control)],timeout:20) == .completed else {
                    evidence("missing-native-control-\(label)")
                    XCTFail("Native AVPlayer control unavailable: \(label)")
                    throw Failure.timedOut(label)
                }
                control.tap()
                return
            }
        }
        // WebKit's AX tree can lag a replaced video surface. Touch the actual
        // visible DOM control, with a fresh hit test, rather than invoking JS.
        if ["Fullscreen", "Exit Fullscreen", "Pause video", "Play video", "Keep playing at bottom of app"].contains(label) {
            let state = try waitFor("Visible player button: \(label)") {
                let buttons = $0["playerButtons"] as? [String: [String: Any]] ?? [:]
                return self.number($0,"observedAt") > Date().timeIntervalSince1970*1000-1500 &&
                    buttons.values.contains { $0["label"] as? String == label && $0["hittable"] as? Bool == true }
            }
            let buttons = state["playerButtons"] as? [String: [String: Any]] ?? [:]
            let button = buttons.values.first { $0["label"] as? String == label }!
            app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx:number(button,"x"),dy:number(button,"y"))).tap()
            return
        }
        let button = app.webViews.buttons.matching(identifier: label).firstMatch
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        guard XCTWaiter.wait(for: [expectation], timeout: 20) == .completed else {
            evidence("missing-button-\(label)")
            XCTFail("App button is unavailable: \(label)")
            throw Failure.timedOut(label)
        }
        button.tap()

    }


    // This test reads the actual Swift AVPlayer state, never a mocked clock.
    // All media transitions use physical iPhone/iPad taps or Home.
    func testNativeSingleAVPlayerVideoAudioMiniHome() throws {
        let button = app.buttons["ist-simulator-open"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Native HLS launch button missing")
        button.tap()
        let opened = try waitFor("Native AVPlayer ready with actual decoded video", timeout: 140) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["active"] as? Bool == true &&
                n["ready"] as? Bool == true &&
                n["sameItem"] as? Bool == true &&
                n["mode"] as? String == "video" &&
                self.number(n,"videoWidth") > 0 &&
                self.number(n,"itemEpoch") == 1
        }
        let first = opened["nativePlayer"] as? [String:Any] ?? [:]
        let id = first["id"] as? String ?? ""
        XCTAssertTrue(id.hasPrefix("video:"))
        let start=self.number(first,"position")
        _ = try waitFor("One AVPlayer video clock must advance", timeout: 45) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["id"] as? String == id &&
                n["playing"] as? Bool == true &&
                self.number(n,"position") > start + 1.5 &&
                self.number(n,"itemEpoch") == 1
        }
        evidence("native-video-moving-clock")
        XCTAssertFalse(snapshot()["audioPlaying"] as? Bool ?? true,
                       "WebKit audio must never play beside native video")
        XCTAssertEqual(number(snapshot(),"playerCount"),0,accuracy:0,
                       "No HTML video decoder should exist")

        try tapWebButton("Audio")
        let audioState = try waitFor("Audio mode shares AVPlayerItem without seek", timeout: 35) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["mode"] as? String == "audio" &&
                n["mode"] as? String == "audio" &&
                n["id"] as? String == id &&
                n["sameItem"] as? Bool == true &&
                self.number(n,"itemEpoch") == 1
        }
        let audioTime=self.number(audioState["nativePlayer"] as? [String:Any] ?? [:],"position")
        _ = try waitFor("Actual native audio clock continues", timeout: 30) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["playing"] as? Bool == true &&
                self.number(n,"position") > audioTime + 1 &&
                self.number(n,"itemEpoch") == 1
        }
        XCTAssertFalse(snapshot()["audioPlaying"] as? Bool ?? true)
        evidence("native-audio-same-item")

        try tapWebButton("Video")
        _ = try waitFor("Video returned on original native item", timeout: 35) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["mode"] as? String == "video" &&
                n["mode"] as? String == "video" &&
                n["id"] as? String == id &&
                self.number(n,"itemEpoch") == 1 &&
                n["playing"] as? Bool == true
        }
        let beforeHome=number(snapshot()["nativePlayer"] as? [String:Any] ?? [:],"position")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 6)
        app.activate()
        _ = try waitFor("Same native AVPlayer continues after Home and reopening", timeout: 45) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["id"] as? String == id &&
                n["active"] as? Bool == true &&
                self.number(n,"itemEpoch") == 1 &&
                self.number(n,"position") > beforeHome + 1
        }
        evidence("native-home-reopened")
        try tapWebButton("Keep playing at bottom of app")
        _ = try waitFor("Mini keeps identical AVPlayerItem", timeout: 30) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["minimized"] as? Bool == true &&
                n["layout"] as? String == "mini" &&
                n["id"] as? String == id &&
                self.number(n,"itemEpoch") == 1
        }
        evidence("native-mini-one-player")
    }

    func testAppleSignInButtonIsVisible() throws {
        try tapWebButton("Account")
        let apple = app.webViews.buttons.matching(identifier: "Continue with Apple").firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 20), "Official Continue with Apple button must be present")
        XCTAssertTrue(apple.isHittable, "Continue with Apple button must be visible and tappable")
        evidence("apple-google-matched-pills")
    }

    func testLauncherIconOnHomeScreen() throws {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "launcher-icon-home-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.activate()
        _ = try waitFor("App returns from launcher icon preview") { self.number($0, "observedAt") > Date().timeIntervalSince1970*1000-1500 }
    }

    func testTabSwipesNavigateBothDirections() throws {
        try tapWebButton("Home")
        func swipe(_ left: Bool, to screen: String) throws {
            let current = snapshot()["screen"] as? String ?? ""
            let state = try waitFor("Settled content for swipe from \(current)") {
                $0["screen"] as? String == current && $0["pageLoading"] as? Bool == false &&
                self.number($0,"observedAt") > Date().timeIntervalSince1970*1000-1500 && self.number($0,"tabSwipeY") >= 180
            }
            let y = number(state, "tabSwipeY")
            let web = app.webViews.firstMatch
            let width = web.frame.width
            let start = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * (left ? 0.8 : 0.2), dy: y))
            let end = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * (left ? 0.2 : 0.8), dy: y))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = try waitFor("Swipe must open \(screen)") { $0["screen"] as? String == screen }
        }
        for screen in ["shiurim", "live", "library", "account"] { try swipe(true, to: screen) }
        try swipe(true, to: "account") // No wrapping past the last tab.
        for screen in ["library", "live", "shiurim", "home"] { try swipe(false, to: screen) }
        try swipe(false, to: "home")
        evidence("tab-swipes")
    }

    private func openSample() throws {
        let button = app.buttons["ist-simulator-open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let acceptanceDeadline = Date().addingTimeInterval(4)
        while Date() < acceptanceDeadline {
            let now = snapshot()
            if now["opening"] as? Bool == true ||
                !(now["id"] as? String ?? "").isEmpty ||
                !(now["error"] as? String ?? "").isEmpty { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let accepted = snapshot()
        if accepted["opening"] as? Bool != true &&
            (accepted["id"] as? String ?? "").isEmpty &&
            (accepted["error"] as? String ?? "").isEmpty { button.tap() }
        let state = try waitFor("Same-shiur native HLS/MP4 video must become visible",timeout:150) { s in
            let native = s["nativePlayer"] as? [String:Any] ?? [:]
            let source = s["videoSource"] as? String ?? ""
            let sameShiurMP4 = s["backend"] as? String == "mp4" &&
                source.contains("/media/") && source.contains("/video.mp4")
            if native["active"] as? Bool == true {
                return s["mode"] as? String == "video" &&
                    s["ready"] as? Bool == true &&
                    ["hls-native","mp4"].contains(s["backend"] as? String ?? "") &&
                    (s["id"] as? String) == (s["sampleId"] as? String) &&
                    native["mode"] as? String == "video" &&
                    native["ready"] as? Bool == true &&
                    native["playing"] as? Bool == true &&
                    native["layerReady"] as? Bool == true &&
                    self.number(native,"videoWidth") > 0 &&
                    self.number(native,"surfaceWidth") > 40 &&
                    self.number(native,"surfaceHeight") > 30 &&
                    self.number(native,"decodedFrames") >= 1 &&
                    self.number(native,"position") >= 28
            }
            return s["mode"] as? String == "video" && s["ready"] as? Bool == true &&
                (s["backend"] as? String == "hls-native" || sameShiurMP4) &&
                (s["id"] as? String) == (s["sampleId"] as? String) &&
                s["videoPlaying"] as? Bool == true &&
                s["videoVisible"] as? Bool == true &&
                self.number(s,"videoTime") >= 28
        }
        XCTAssertEqual(number(state,"speed"),1,accuracy:0.01)
        let native=state["nativePlayer"] as? [String:Any] ?? [:]
        XCTAssertEqual(number(state,"playerCount"), native["active"] as? Bool == true ? 0 : 1,
                       "Native AVPlayer must not create an HTML video decoder")
        evidence("fresh-video")
    }

    private func assertMovingVideo() throws {
        let before = try waitFor("Video decoder must be presenting frames",timeout:45) { s in
            let native = s["nativePlayer"] as? [String:Any] ?? [:]
            if native["active"] as? Bool == true {
                return native["mode"] as? String == "video" &&
                    native["playing"] as? Bool == true &&
                    native["ready"] as? Bool == true &&
                    native["layerReady"] as? Bool == true &&
                    self.number(native,"videoWidth") > 0 &&
                    self.number(native,"decodedFrames") >= 1
            }
            return s["videoPlaying"] as? Bool == true && s["videoVisible"] as? Bool == true &&
                s["initializing"] as? Bool != true && s["decoderLoading"] as? Bool != true &&
                self.number(s,"frames") >= 1 && self.number(s,"frameTime") > 0
        }
        let nativeBefore = before["nativePlayer"] as? [String:Any] ?? [:]
        _ = try waitFor("Decoded frames and the media clock must advance",timeout:45) { s in
            let n = s["nativePlayer"] as? [String:Any] ?? [:]
            if nativeBefore["active"] as? Bool == true {
                return n["id"] as? String == nativeBefore["id"] as? String &&
                    n["playing"] as? Bool == true &&
                    n["layerReady"] as? Bool == true &&
                    self.number(n,"itemEpoch") == self.number(nativeBefore,"itemEpoch") &&
                    self.number(n,"decodedFrames") >= self.number(nativeBefore,"decodedFrames") + 2 &&
                    self.number(n,"frameTime") > self.number(nativeBefore,"frameTime") + 0.5 &&
                    self.number(n,"position") > self.number(nativeBefore,"position") + 0.5
            }
            return s["videoPlaying"] as? Bool == true && s["videoVisible"] as? Bool == true &&
                self.number(s,"frames") > self.number(before,"frames") + 2 &&
                self.number(s,"frameTime") > self.number(before,"frameTime") + 0.5 &&
                self.number(s,"videoTime") > self.number(before,"videoTime") + 0.5
        }
    }

    func testFreshVideoHasMovingFrames() throws {
        try openSample()
        try assertMovingVideo()
    }

    func testReportedShiurDirectPlaybackAndUnlistedEmbed() throws {
        let button = app.buttons["ist-simulator-open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let state = try waitFor("Reported IST-DL6067 must start as visible direct video", timeout: 150) {
            $0["id"] as? String == "1233236785:585d5d53db" && $0["ready"] as? Bool == true &&
            $0["mode"] as? String == "video" && $0["videoVisible"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true &&
            ["mp4", "hls-native"].contains($0["backend"] as? String ?? "")
        }
        XCTAssertEqual(state["videoSource"] as? String, state["reportedExpectedSource"] as? String)
        let sources = state["reportedSources"] as? [String: Any] ?? [:]
        if (sources["hls"] as? String ?? "").isEmpty {
            XCTAssertEqual(state["backend"] as? String, "mp4", "MP4-only shiur must not fall back to Vimeo")
        }
        let embed = URLComponents(string: state["vimeoEmbed"] as? String ?? "")
        XCTAssertEqual(embed?.path, "/video/1233236785")
        XCTAssertEqual(embed?.queryItems?.first { $0.name == "h" }?.value, "585d5d53db")
        XCTAssertEqual(state["directFallbackId"] as? String, "")
        XCTAssertFalse(state["fallbackBanner"] as? Bool ?? true)
        XCTAssertEqual(number(state, "playerCount"),
                       ((state["nativePlayer"] as? [String:Any])?["active"] as? Bool) == true ? 0 : 1,
                       "Do not construct a second HTML media player")
        try assertMovingVideo()
        evidence("reported-shiur-moving")
        try tapWebButton("Pause video")
        _ = try waitFor("Reported shiur native Pause") { $0["videoPlaying"] as? Bool == false }
        let paused = number(snapshot(), "videoTime")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(number(snapshot(), "videoTime"), paused, accuracy: 0.3)
        try tapWebButton("Play video")
        try assertMovingVideo()
        XCTAssertFalse(snapshot()["fallbackBanner"] as? Bool ?? true)
        evidence("reported-shiur-resumed")
    }

    func testReopeningSameShiurKeepsPlayerAndClock() throws {
        try openSample()
        try assertMovingVideo()
        let before = number(snapshot(), "videoTime")
        let button = app.buttons["ist-simulator-reopen"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        _ = try waitFor("Same-shiur deep link must keep player ready and advancing") {
            $0["ready"] as? Bool == true && $0["videoPlaying"] as? Bool == true &&
            $0["controlsVisible"] as? Bool == true && self.number($0, "videoTime") > before + 1 &&
            self.number($0, "playerCount") == (((($0["nativePlayer"] as? [String:Any])?["active"] as? Bool) == true) ? 0 : 1)
        }
        try assertMovingVideo()
        evidence("same-shiur-reopen")
    }

    func testAudioToVideoPreservesPositionAndMoves() throws {
        try openSample()
        try assertMovingVideo()
        let videoTime = number(snapshot(), "videoTime")
        try tapWebButton("Audio")
        let audio = try waitFor("Audio switch must resume near the video position") {
            $0["mode"] as? String == "audio" &&
            ($0["nativeAudioPlaying"] as? Bool == true || $0["audioPlaying"] as? Bool == true) &&
            $0["pendingSeek"] as? Bool == false &&
            (self.number($0, "nativeAudioTime") > 0 ?
                self.number($0, "nativeAudioTime") : self.number($0, "audioTime")) >= videoTime - 2
        }
        evidence("watch-audio")
        let position = number(audio,"nativeAudioTime") > 0 ? number(audio,"nativeAudioTime") : number(audio,"audioTime")
        try tapWebButton("Video")
        _ = try waitFor("Video switch must resume near the audio position") {
            $0["ready"] as? Bool == true && $0["mode"] as? String == "video" &&
            $0["videoPlaying"] as? Bool == true && self.number($0, "videoTime") >= position - 2
        }
        XCTAssertFalse(snapshot()["audioPlaying"] as? Bool ?? true, "Only video should own playback")
        try assertMovingVideo()
        evidence("audio-to-video")
    }

    func testHomeAndReopenContinuesPosition() throws {
        try openSample()
        try assertMovingVideo()
        let before = number(snapshot(),"videoTime")
        let initial = snapshot()["nativePlayer"] as? [String:Any] ?? [:]
        let itemEpoch=number(initial,"itemEpoch")
        let itemID=initial["id"] as? String ?? ""
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 20)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "home-during-playback"
        home.lifetime = .keepAlways
        add(home)
        app.activate()
        if initial["active"] as? Bool == true {
            _ = try waitFor("One native AVPlayer must retain the item and advance across Home/reopen",timeout:65) { s in
                let n=s["nativePlayer"] as? [String:Any] ?? [:]
                return n["active"] as? Bool == true &&
                    n["playing"] as? Bool == true &&
                    n["id"] as? String == itemID &&
                    self.number(n,"itemEpoch") == itemEpoch &&
                    self.number(n,"position") >= before+4 &&
                    n["layerReady"] as? Bool == true
            }
        } else {
            let result = try waitFor("Native background audio samples must be available") {
                (($0["nativeAudio"] as? [String:Any])?["backgroundSamples"] as? [Double] ?? []).count >= 3
            }
            let samples = (result["nativeAudio"] as? [String:Any])?["backgroundSamples"] as? [Double] ?? []
            XCTAssertGreaterThan((samples.last ?? 0) - (samples.first ?? 0),4)
            _ = try waitFor("Reopen must resume video",timeout:60) {
                $0["videoPlaying"] as? Bool == true && self.number($0,"videoTime") >= before+3
            }
        }
        try assertMovingVideo()
        evidence("home-reopen")
    }

    private func videoPoint(_ x: Double, _ y: Double) -> XCUICoordinate {
        let s = snapshot()
        let native = s["nativePlayer"] as? [String:Any] ?? [:]
        if native["active"] as? Bool == true {
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: number(native,"surfaceX") + number(native,"surfaceWidth") * x,
                dy: number(native,"surfaceY") + number(native,"surfaceHeight") * y))
        }
        return app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: number(s,"videoX") + number(s,"videoWidth") * x,
            dy: number(s,"videoY") + number(s,"videoHeight") * y))
    }

    func testFullscreenExitKeepsPlayingAndPausedStaysPaused() throws {
        try openSample(); try assertMovingVideo()
        try tapWebButton("Fullscreen")
        _ = try waitFor("Fullscreen must open") { $0["fullscreen"] as? Bool == true }
        try assertMovingVideo()
        try tapWebButton("Pause video")
        _ = try waitFor("Fullscreen Pause must stop playback") { $0["fullscreen"] as? Bool == true && $0["videoPlaying"] as? Bool == false }
        let paused = number(snapshot(),"videoTime")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(number(snapshot(),"videoTime"), paused, accuracy: 0.5)
        try tapWebButton("Play video")
        _ = try waitFor("Fullscreen Play must resume playback") { $0["fullscreen"] as? Bool == true && $0["videoPlaying"] as? Bool == true }
        try assertMovingVideo()
        let before = number(snapshot(),"videoTime")
        try tapWebButton("Exit Fullscreen")
        _ = try waitFor("Fullscreen exit must keep playing") { $0["fullscreen"] as? Bool == false && $0["videoPlaying"] as? Bool == true && self.number($0,"videoTime") > before + 1 }
        try assertMovingVideo()
        try tapWebButton("Pause video")
        _ = try waitFor("Explicit Pause") { $0["videoPlaying"] as? Bool == false }
        try tapWebButton("Fullscreen"); try tapWebButton("Exit Fullscreen")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(snapshot()["videoPlaying"] as? Bool ?? true)
        evidence("fullscreen-exit")
    }

    func testDoubleTapSeeksBothWaysWithoutChangingPause() throws {
        try openSample(); try assertMovingVideo()
        try tapWebButton("Pause video")
        _ = try waitFor("Pause before seeking") { $0["videoPlaying"] as? Bool == false }
        let before=number(snapshot(),"videoTime")
        videoPoint(0.8,0.4).doubleTap()
        _ = try waitFor("Right double tap must seek 15 seconds") { abs(self.number($0,"videoTime") - before - 15)<2 && $0["videoPlaying"] as? Bool == false }
        videoPoint(0.2,0.4).doubleTap()
        _ = try waitFor("Left double tap must seek back 15 seconds") { abs(self.number($0,"videoTime") - before)<2 && $0["videoPlaying"] as? Bool == false }
        try tapWebButton("Play video"); try assertMovingVideo()
        let playing=number(snapshot(),"videoTime")
        videoPoint(0.8,0.4).doubleTap()
        _ = try waitFor("Double tap while playing must keep playing", timeout: 6) { self.number($0,"videoTime")>playing+13 && $0["videoPlaying"] as? Bool == true }
        try assertMovingVideo()
        let backward=number(snapshot(),"videoTime")
        videoPoint(0.2,0.4).doubleTap()
        _ = try waitFor("Left double tap while playing must seek back 15 seconds and keep playing", timeout: 6) {
            abs(self.number($0,"videoTime") - backward + 15)<3 && $0["videoPlaying"] as? Bool == true
        }
        try assertMovingVideo(); evidence("double-tap-seek")
    }

    func testSwipeDownMinimizesPlayingAndPausedVideo() throws {
        try openSample(); try assertMovingVideo()
        videoPoint(0.5,0.15).press(forDuration: 0.05, thenDragTo: videoPoint(0.5,0.85))
        _ = try waitFor("Swipe must minimize playing video") { $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == true }
        try assertMovingVideo()
        let s=snapshot()
        app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:number(s,"expandX"),dy:number(s,"expandY"))).tap()
        _ = try waitFor("Expand before paused swipe") { $0["minimized"] as? Bool == false && $0["controlsVisible"] as? Bool == true }
        try tapWebButton("Pause video")
        _ = try waitFor("Pause before swipe") { $0["videoPlaying"] as? Bool == false }
        videoPoint(0.5,0.15).press(forDuration: 0.05, thenDragTo: videoPoint(0.5,0.85))
        _ = try waitFor("Swipe must minimize paused video") { $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == false }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(snapshot()["videoPlaying"] as? Bool ?? true); evidence("swipe-minimize")
    }

    func testPausedVideoDoesNotStartOnHome() throws {
        try openSample(); try tapWebButton("Pause video")
        _ = try waitFor("Pause before Home") { $0["videoPlaying"] as? Bool == false }
        XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 4); app.activate()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(snapshot()["videoPlaying"] as? Bool ?? true)
        let native = snapshot()["nativeAudio"] as? [String:Any] ?? [:]
        XCTAssertFalse(native["active"] as? Bool ?? true)
        evidence("paused-home")
    }

    func testZZAppStoreScreenshotsOfAllPublicPages() throws {
        for _ in 0..<26 {
            let previous=snapshot()["storePage"] as? String ?? ""
            app.buttons["ist-simulator-next-page"].tap()
            let state = try waitFor("Screenshot page must load", timeout: 150) { !($0["storeError"] as? String ?? "").isEmpty || ($0["storeReady"] as? Bool == true && ($0["storePage"] as? String ?? "") != previous) }
            XCTAssertEqual(state["storeError"] as? String ?? "", "")
            let name=state["storePage"] as? String ?? "unknown"
            app.buttons["ist-simulator-clean-capture"].tap()
            Thread.sleep(forTimeInterval: 0.7)
            let screenshot=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
            screenshot.name="store-\(name)"; screenshot.lifetime = .keepAlways; add(screenshot)
            let ready=NSPredicate(format:"exists == true AND hittable == true")
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:app.buttons["ist-simulator-next-page"])],timeout:8),.completed)
        }
    }

    func testMiniPlayerThenExpandKeepsMoving() throws {
        try openSample()
        try assertMovingVideo()
        try tapWebButton("Keep playing at bottom of app")
        _ = try waitFor("Mini player must retain video playback") {
            $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == true
        }
        try assertMovingVideo()
        evidence("mini-player")
        // The real mini-player expand control uses a role=button on the overlay.
        let expand = app.webViews.descendants(matching: .any).matching(identifier: "Open video").firstMatch
        if expand.exists && expand.isHittable {
            expand.tap()
        } else {
            // Some app versions mark mini chrome aria-hidden. Tap the observed
            // center of the real expand hit area instead of inventing a button.
            let state = snapshot()
            let x = number(state, "expandX"), y = number(state, "expandY")
            XCTAssertGreaterThan(x, 0)
            XCTAssertGreaterThan(y, 0)
            app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: y)).tap()
        }
        _ = try waitFor("Expanded player controls must return") {
            $0["minimized"] as? Bool == false && $0["controlsVisible"] as? Bool == true
        }
        try assertMovingVideo()
        evidence("expanded-video")
    }

    func testPictureInPictureAndReopenRestoresControls() throws {
        try openSample()
        try assertMovingVideo()
        let before=snapshot()
        let isNative=((before["nativePlayer"] as? [String:Any])?["active"] as? Bool) == true
        guard before["pipSupported"] as? Bool == true else {
            throw XCTSkip("iOS simulator runtime does not support system PiP; a physical device test is required")
        }
        try tapWebButton("Picture in Picture")
        _ = try waitFor("System PiP must start with the current AVPlayer item",timeout:35) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["pip"] as? Bool == true &&
                (!isNative || (n["active"] as? Bool == true && n["pipActive"] as? Bool == true))
        }
        evidence("pip-active")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        _ = try waitFor("Reopen from PiP must restore inline video and controls",timeout:50) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["pip"] as? Bool == false && s["videoVisible"] as? Bool == true &&
                s["controlsVisible"] as? Bool == true &&
                (!isNative || (n["mode"] as? String == "video" &&
                               n["layerReady"] as? Bool == true &&
                               n["pipActive"] as? Bool == false))
        }
        try assertMovingVideo()
        evidence("pip-reopen")
    }


}
