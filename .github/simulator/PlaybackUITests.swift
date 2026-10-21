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
        // This predicate reads the simulator's loopback observations. Giving
        // XCTest the application here makes each false poll collect a large
        // accessibility debug snapshot, which can stall the app's main queue
        // past the video controller's eight-second deadline on iPad.
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: NSObject())
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
                "Video quality": "irgun-native-quality",
                "Playback speed": "irgun-native-speed",
                "Pause video": "irgun-native-play",
                "Play video": "irgun-native-play",
                "Picture in Picture": "irgun-native-pip",
                "Keep playing at bottom of app": "irgun-native-mini"
            ]
            if let identifier = mappings[label] {
                // Use the actual, currently hittable UIKit button bounds.
                // An AX query plus .tap() can take longer than the eight-second
                // controller lifetime on iPad, even after hittable was true.
                if native["controlsVisible"] as? Bool == true && native["playRequested"] as? Bool == true &&
                   number(native,"controlsHideRemaining") < 5 {
                    videoPoint(0.5, 0.25).tap()
                    _ = try waitFor("Picture tap refreshes expiring control display", timeout: 5) { s in
                        let n = s["nativePlayer"] as? [String: Any] ?? [:]
                        // The timer may expire while XCTest delivers the tap;
                        // in that case the same tap already reveals a fresh UI.
                        return n["controlsVisible"] as? Bool == false || self.number(n,"controlsHideRemaining") >= 6
                    }
                }
                let current = snapshot()["nativePlayer"] as? [String: Any] ?? [:]
                if current["controlsVisible"] as? Bool == false && current["layout"] as? String != "mini" {
                    videoPoint(0.5, 0.25).tap()
                    _ = try waitFor("Tap reveals native controls", timeout: 5) { $0["controlsVisible"] as? Bool == true }
                }
                let ready = try waitFor("Visible native button: \(label)", timeout: 5) { s in
                    let n = s["nativePlayer"] as? [String: Any] ?? [:]
                    let buttons = n["buttons"] as? [String: [String: Any]] ?? [:]
                    return n["controlsVisible"] as? Bool == true && buttons[identifier]?["hittable"] as? Bool == true
                }
                let buttons = (ready["nativePlayer"] as? [String: Any])?["buttons"] as? [String: [String: Any]] ?? [:]
                let point = buttons[identifier] ?? [:]
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: number(point,"x"),dy: number(point,"y"))).tap()
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
        // The WKWebView may still be replacing its initial document. A native
        // button tap made during that narrow window can be lost, even though
        // the library catalogue already appears ready. Retry only when the
        // simulator reports it did not accept the request at all.
        var accepted = false
        for _ in 0..<3 {
            button.tap()
            let deadline = Date().addingTimeInterval(7)
            while Date() < deadline {
                let state = snapshot()
                if state["opening"] as? Bool == true ||
                   !(state["sampleId"] as? String ?? "").isEmpty ||
                   !(state["id"] as? String ?? "").isEmpty ||
                   !(state["error"] as? String ?? "").isEmpty {
                    accepted = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            if accepted { break }
        }
        XCTAssertTrue(accepted, "Simulator never accepted native HLS start request")
        let opened = try waitFor("Native AVPlayer ready with actual decoded video", timeout: 140) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["active"] as? Bool == true &&
                n["ready"] as? Bool == true &&
                n["sameItem"] as? Bool == true &&
                n["mode"] as? String == "video" &&
                self.number(n,"videoWidth") > 0 &&
                self.number(n,"itemEpoch") >= 1
        }
        let first = opened["nativePlayer"] as? [String:Any] ?? [:]
        let epoch = number(first,"itemEpoch")
        let id = first["id"] as? String ?? ""
        XCTAssertTrue(id.hasPrefix("video:"))
        let start=self.number(first,"position")
        _ = try waitFor("One AVPlayer video clock must advance", timeout: 45) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["id"] as? String == id &&
                n["playing"] as? Bool == true &&
                self.number(n,"position") > start + 1.5 &&
                self.number(n,"itemEpoch") == epoch
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
                self.number(n,"itemEpoch") == epoch
        }
        let audioTime=self.number(audioState["nativePlayer"] as? [String:Any] ?? [:],"position")
        _ = try waitFor("Actual native audio clock continues", timeout: 30) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return n["playing"] as? Bool == true &&
                self.number(n,"position") > audioTime + 1 &&
                self.number(n,"itemEpoch") == epoch
        }
        XCTAssertFalse(snapshot()["audioPlaying"] as? Bool ?? true)
        evidence("native-audio-same-item")

        try tapWebButton("Video")
        _ = try waitFor("Video returned on original native item", timeout: 35) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["mode"] as? String == "video" &&
                n["mode"] as? String == "video" &&
                n["id"] as? String == id &&
                self.number(n,"itemEpoch") == epoch &&
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
                self.number(n,"itemEpoch") == epoch &&
                self.number(n,"position") > beforeHome + 1
        }
        evidence("native-home-reopened")
        try tapWebButton("Keep playing at bottom of app")
        _ = try waitFor("Mini keeps identical AVPlayerItem", timeout: 30) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["minimized"] as? Bool == true &&
                n["layout"] as? String == "mini" &&
                n["id"] as? String == id &&
                self.number(n,"itemEpoch") == epoch
        }
        evidence("native-mini-one-player")
    }

    func testAppleSignInButtonIsVisible() throws {
        try tapWebButton("Account")
        let apple = app.webViews.buttons.matching(identifier: "Continue with Apple").firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 20), "Official Continue with Apple button must be present")
        XCTAssertTrue(apple.isHittable, "Continue with Apple button must be visible and tappable")
        // Screenshot capture is not part of the Sign-In accessibility assertion.
        // On heavily loaded iPhone simulators it can time out after the button
        // is already verified; final-state diagnostics are captured by teardown.
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
                $0["screen"] as? String == current &&
                $0["renderedScreen"] as? String == current &&
                $0["tabSwipeReady"] as? Bool == true &&
                $0["pageLoading"] as? Bool == false &&
                self.number($0,"observedAt") > Date().timeIntervalSince1970*1000-1500 &&
                self.number($0,"tabSwipeY") >= 220
            }
            let y = number(state, "tabSwipeY")
            let web = app.webViews.firstMatch
            let width = web.frame.width
            let start = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * (left ? 0.8 : 0.2), dy: y))
            let end = web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * (left ? 0.2 : 0.8), dy: y))
            let beganAt = Date().timeIntervalSince1970 * 1000
            start.press(forDuration: 0.05, thenDragTo: end)
            let settled = try waitFor("Swipe must open \(screen)") {
                $0["screen"] as? String == screen &&
                $0["renderedScreen"] as? String == screen &&
                $0["tabSwipeReady"] as? Bool == true
            }
            if screen != current {
                let motion = settled["tabMotion"] as? [[String:Any]] ?? []
                XCTAssertTrue(motion.contains {
                    self.number($0,"at") >= beganAt && $0["screen"] as? String == current &&
                    (left ? self.number($0,"dx") < -10 : self.number($0,"dx") > 10) &&
                    $0["inert"] as? Bool == true && self.number($0,"media") == 0
                }, "Page must follow the finger before release, with an inert media-free neighbor")
            }
        }
        try swipe(true, to: "shiurim")
        try swipe(false, to: "home") // Immediate reverse must finish normally.
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
        // The same simulator persists the user's selected speed across
        // process restarts and test cases. Only the dedicated speed test
        // should demand 1x after explicitly selecting 1x.
        XCTAssertGreaterThanOrEqual(number(state,"speed"),0.5)
        XCTAssertLessThanOrEqual(number(state,"speed"),2.0)
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
        let state = try waitFor("A live unlisted shiur with a direct source must start visibly", timeout: 150) { s in
            if !(s["error"] as? String ?? "").isEmpty { return true }
            let expectedId = s["reportedExpectedId"] as? String ?? ""
            return !expectedId.isEmpty && s["id"] as? String == expectedId &&
                s["ready"] as? Bool == true && s["mode"] as? String == "video" &&
                s["videoVisible"] as? Bool == true && s["videoPlaying"] as? Bool == true &&
                ["mp4", "hls-native"].contains(s["backend"] as? String ?? "")
        }
        let startupError = state["error"] as? String ?? ""
        XCTAssertTrue(startupError.isEmpty, "Could not select a live unlisted shiur for direct playback: \(startupError)")
        let expectedId = state["reportedExpectedId"] as? String ?? ""
        let expectedVimeoId = state["reportedExpectedVimeoId"] as? String ?? ""
        let expectedPrivacyHash = state["reportedExpectedPrivacyHash"] as? String ?? ""
        XCTAssertFalse(expectedId.isEmpty)
        XCTAssertFalse(expectedVimeoId.isEmpty)
        if expectedId.contains(":") {
            XCTAssertFalse(expectedPrivacyHash.isEmpty, "An actual unlisted video must retain its privacy hash")
        } else {
            XCTAssertTrue(expectedPrivacyHash.isEmpty, "Do not manufacture a privacy hash for a normal video")
            print("COVERAGE NOTICE: current catalog has no unlisted video with a direct MP4; verifying backed-up native direct playback")
        }
        XCTAssertEqual(state["id"] as? String, expectedId)
        XCTAssertEqual(state["videoSource"] as? String, state["reportedExpectedSource"] as? String)
        let sources = state["reportedSources"] as? [String: Any] ?? [:]
        if (sources["hls"] as? String ?? "").isEmpty {
            XCTAssertEqual(state["backend"] as? String, "mp4", "MP4-only shiur must not fall back to Vimeo")
        }
        let embed = URLComponents(string: state["vimeoEmbed"] as? String ?? "")
        XCTAssertEqual(embed?.path, "/video/\(expectedVimeoId)")
        if !expectedPrivacyHash.isEmpty {
            XCTAssertEqual(embed?.queryItems?.first { $0.name == "h" }?.value, expectedPrivacyHash,
                           "The actual unlisted Vimeo privacy hash must survive URL construction")
        } else {
            XCTAssertNil(embed?.queryItems?.first { $0.name == "h" },
                         "Do not invent an unlisted Vimeo hash for a public video")
        }
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
        let initial = snapshot()
        let before = number(initial, "videoTime")
        let nativeBefore = initial["nativePlayer"] as? [String: Any] ?? [:]
        let button = app.buttons["ist-simulator-reopen"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        _ = try waitFor("Same-shiur deep link must keep player ready and advancing") { state in
            let native = state["nativePlayer"] as? [String: Any] ?? [:]
            let isNative = nativeBefore["active"] as? Bool == true
            return state["ready"] as? Bool == true && state["videoPlaying"] as? Bool == true &&
                self.number(state, "videoTime") > before + 1 &&
                self.number(state, "playerCount") == (isNative ? 0 : 1) &&
                (!isNative || (native["active"] as? Bool == true &&
                    native["id"] as? String == nativeBefore["id"] as? String &&
                    self.number(native, "itemEpoch") == self.number(nativeBefore, "itemEpoch")))
        }
        try assertMovingVideo()
        // Controls may have reached their inactivity deadline while XCTest
        // delivers the deep link. Verify real controls remain usable, rather
        // than requiring them to stay visible throughout ongoing playback.
        try tapWebButton("Pause video")
        _ = try waitFor("Reopened player responds to Pause") { $0["videoPlaying"] as? Bool == false }
        try tapWebButton("Play video")
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
        let tapCount = number(snapshot()["nativePlayer"] as? [String:Any] ?? [:],"fullscreenButtonTaps")
        try tapWebButton("Exit Fullscreen")
        _ = try waitFor("UIKit must receive the real iPad exit-fullscreen tap",timeout:20) { state in
            let native = state["nativePlayer"] as? [String:Any] ?? [:]
            return native["active"] as? Bool != true ||
                self.number(native,"fullscreenButtonTaps") > tapCount
        }
        _ = try waitFor("Fullscreen exit must keep playing",timeout:45) { state in
            let native = state["nativePlayer"] as? [String:Any] ?? [:]
            return state["fullscreen"] as? Bool == false &&
                state["videoPlaying"] as? Bool == true &&
                self.number(state,"videoTime") > before + 1 &&
                (native["active"] as? Bool != true || native["layout"] as? String == "inline")
        }
        try assertMovingVideo()
        try tapWebButton("Pause video")
        _ = try waitFor("Explicit Pause") { $0["videoPlaying"] as? Bool == false }
        try tapWebButton("Fullscreen"); try tapWebButton("Exit Fullscreen")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(snapshot()["videoPlaying"] as? Bool ?? true)
        evidence("fullscreen-exit")
    }

    // Real physical iPhone/iPad taps: choose actual HLS renditions, confirm
    // decoded height (not merely a label), and preserve the playback timestamp.
    func testManualHLSQualityKeepsDecodedResolutionAndPlaybackPosition() throws {
        try openSample()
        try assertMovingVideo()
        let initial = snapshot()
        guard initial["backend"] as? String == "hls-native",
              (initial["nativePlayer"] as? [String:Any])?["active"] as? Bool == true else {
            throw XCTSkip("Manual HLS rendition verification requires the native HLS sample")
        }
        let variantState = try waitFor("Real HLS playlist advertises multiple qualities", timeout: 20) { state in
            let native = state["nativePlayer"] as? [String:Any] ?? [:]
            return (native["qualities"] as? [Int] ?? []).count >= 2
        }
        let choices = (variantState["nativePlayer"] as? [String:Any])?["qualities"] as? [Int] ?? []
        let exactSequence = [720,480,360].filter { choices.contains($0) }
        let sequence = exactSequence.count >= 2 ? exactSequence : [choices.first!, choices.last!]
        let startItemID = (variantState["nativePlayer"] as? [String:Any])?["id"] as? String ?? ""
        for height in sequence {
            let before = snapshot()["nativePlayer"] as? [String:Any] ?? [:]
            let started = Date()
            try tapWebButton("Video quality")
            let option = app.buttons["\(height)p"].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 12),
                          "The actual native quality menu must offer \(height)p")
            option.tap()
            let afterState = try waitFor("Native AVPlayer must decode the chosen \(height)p rendition", timeout: 65) { state in
                let n = state["nativePlayer"] as? [String:Any] ?? [:]
                return self.number(n, "qualityHeight") == Double(height) &&
                    self.number(n, "videoHeight") == Double(height) &&
                    self.number(n, "decodedFrames") >= 2 &&
                    n["playing"] as? Bool == true
            }
            let after = afterState["nativePlayer"] as? [String:Any] ?? [:]
            XCTAssertEqual(after["id"] as? String, startItemID, "Quality must keep the same lecture")
            XCTAssertGreaterThan(self.number(after,"itemEpoch"), self.number(before,"itemEpoch"),
                                 "A fixed HLS playlist should replace only the AVPlayerItem")
            XCTAssertGreaterThanOrEqual(self.number(after,"position"),
                                        self.number(before,"position") - 1.5,
                                        "Quality selection must not rewind playback")
            XCTAssertLessThanOrEqual(self.number(after,"position"),
                                     self.number(before,"position") + Date().timeIntervalSince(started) *
                                     max(1, self.number(after,"rate")) + 6,
                                     "Quality selection must not jump ahead")
        }
        let beforeAuto = snapshot()["nativePlayer"] as? [String:Any] ?? [:]
        let beganAuto = Date()
        try tapWebButton("Video quality")
        let automatic = app.buttons["Auto"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 12))
        automatic.tap()
        let autoState = try waitFor("Auto restores adaptive HLS on the same lecture", timeout: 65) { state in
            let n = state["nativePlayer"] as? [String:Any] ?? [:]
            return self.number(n,"qualityHeight") == 0 &&
                n["id"] as? String == startItemID &&
                n["playing"] as? Bool == true &&
                self.number(n,"decodedFrames") >= 2
        }
        let afterAuto = autoState["nativePlayer"] as? [String:Any] ?? [:]
        XCTAssertGreaterThanOrEqual(self.number(afterAuto,"position"),self.number(beforeAuto,"position") - 1.5)
        XCTAssertLessThanOrEqual(self.number(afterAuto,"position"),
                                 self.number(beforeAuto,"position") + Date().timeIntervalSince(beganAuto) + 6)
        try assertMovingVideo()
        evidence("native-quality-renditions")
    }

    func testDoubleTapSeeksBothWaysWithoutChangingPause() throws {
        try openSample(); try assertMovingVideo()
        try tapWebButton("Pause video")
        let pausedState = try waitFor("Pause before seeking") { state in
            let native = state["nativePlayer"] as? [String: Any] ?? [:]
            if native["active"] as? Bool == true {
                return native["playing"] as? Bool == false &&
                    native["playRequested"] as? Bool == false
            }
            return state["videoPlaying"] as? Bool == false
        }
        let nativePaused = pausedState["nativePlayer"] as? [String: Any] ?? [:]
        let usesNativePlayer = nativePaused["active"] as? Bool == true
        let before = usesNativePlayer ? number(nativePaused, "position") : number(pausedState, "videoTime")
        if usesNativePlayer {
            let previousTapCount = number(nativePaused, "doubleTapCount")
            videoPoint(0.8,0.4).doubleTap()
            let forward = try waitFor("Native right double tap must seek 15 seconds and remain paused", timeout: 15) { state in
                let native = state["nativePlayer"] as? [String: Any] ?? [:]
                return self.number(native, "doubleTapCount") > previousTapCount &&
                    self.number(native, "doubleTapOffset") == 15 &&
                    native["doubleTapCompleted"] as? Bool == true &&
                    native["playing"] as? Bool == false &&
                    native["playRequested"] as? Bool == false &&
                    abs(self.number(native, "position") - self.number(native, "doubleTapTarget")) < 2
            }
            let forwardNative = forward["nativePlayer"] as? [String: Any] ?? [:]
            XCTAssertEqual(number(forwardNative, "doubleTapTarget"),
                           number(forwardNative, "doubleTapFrom") + 15, accuracy: 0.25)
            XCTAssertEqual(number(forwardNative, "position"),
                           number(forwardNative, "doubleTapTarget"), accuracy: 2)

            let forwardTapCount = number(forwardNative, "doubleTapCount")
            videoPoint(0.2,0.4).doubleTap()
            let backwardState = try waitFor("Native left double tap must rewind 15 seconds and remain paused", timeout: 15) { state in
                let native = state["nativePlayer"] as? [String: Any] ?? [:]
                return self.number(native, "doubleTapCount") > forwardTapCount &&
                    self.number(native, "doubleTapOffset") == -15 &&
                    native["doubleTapCompleted"] as? Bool == true &&
                    native["playing"] as? Bool == false &&
                    native["playRequested"] as? Bool == false &&
                    abs(self.number(native, "position") - self.number(native, "doubleTapTarget")) < 2
            }
            let backwardNative = backwardState["nativePlayer"] as? [String: Any] ?? [:]
            XCTAssertEqual(number(backwardNative, "doubleTapTarget"),
                           number(backwardNative, "doubleTapFrom") - 15, accuracy: 0.25)
            XCTAssertEqual(number(backwardNative, "position"),
                           number(backwardNative, "doubleTapTarget"), accuracy: 2)
            XCTAssertEqual(number(backwardNative, "position"), before, accuracy: 2)
        } else {
            videoPoint(0.8,0.4).doubleTap()
            _ = try waitFor("Right double tap must seek 15 seconds") {
                abs(self.number($0, "videoTime") - before - 15) < 2 &&
                    $0["videoPlaying"] as? Bool == false
            }
            videoPoint(0.2,0.4).doubleTap()
            _ = try waitFor("Left double tap must seek back 15 seconds") {
                abs(self.number($0, "videoTime") - before) < 2 &&
                    $0["videoPlaying"] as? Bool == false
            }
        }
        try tapWebButton("Play video"); try assertMovingVideo()
        let playing=number(snapshot(),"videoTime")
        videoPoint(0.8,0.4).doubleTap()
        _ = try waitFor("Double tap while playing must keep playing", timeout: 6) { self.number($0,"videoTime")>playing+13 && $0["videoPlaying"] as? Bool == true }
        try assertMovingVideo()
        let beforeBackward = snapshot()
        let nativeBefore = beforeBackward["nativePlayer"] as? [String:Any] ?? [:]
        let previousDoubleTaps = number(nativeBefore,"doubleTapCount")
        let backward = number(beforeBackward,"videoTime")
        videoPoint(0.2,0.4).doubleTap()
        if nativeBefore["active"] as? Bool == true {
            // A playing clock advances during XCTest's touch delivery and AX
            // waits. Verify the actual UIKit recognizer and 15-second AVPlayer
            // seek against its own timestamp, not a stale pre-gesture clock.
            let observed = try waitFor("Native left double tap must reach the AVPlayer", timeout: 15) { s in
                let n = s["nativePlayer"] as? [String:Any] ?? [:]
                return self.number(n,"doubleTapCount") > previousDoubleTaps &&
                    self.number(n,"doubleTapOffset") == -15
            }
            let seek = observed["nativePlayer"] as? [String:Any] ?? [:]
            let from = number(seek,"doubleTapFrom")
            let target = number(seek,"doubleTapTarget")
            XCTAssertEqual(target, max(0,from-15), accuracy: 0.25,
                           "The native recognizer must request a full 15-second rewind")
            _ = try waitFor("Native left double tap must really rewind and keep playing", timeout: 20) { s in
                let n = s["nativePlayer"] as? [String:Any] ?? [:]
                let age = self.number(n,"doubleTapAge")
                let rate = max(0.75,self.number(n,"rate"))
                let current = self.number(n,"position")
                return n["doubleTapCompleted"] as? Bool == true &&
                    n["playing"] as? Bool == true && s["videoPlaying"] as? Bool == true &&
                    current >= target - 2 &&
                    current <= target + age * rate + 3 &&
                    current < from + age * rate - 8
            }
        } else {
            _ = try waitFor("Left double tap while playing must seek back 15 seconds and keep playing", timeout: 10) {
                abs(self.number($0,"videoTime") - backward + 15)<3 && $0["videoPlaying"] as? Bool == true
            }
        }
        try assertMovingVideo(); evidence("double-tap-seek")
    }

    func testSwipeDownMinimizesPlayingAndPausedVideo() throws {
        try openSample(); try assertMovingVideo()
        // Start on the picture, below the 44pt toolbar. Toolbar buttons own
        // their touches just as they do on Android.
        videoPoint(0.5,0.28).press(forDuration: 0.05, thenDragTo: videoPoint(0.5,0.85))
        _ = try waitFor("Swipe must minimize playing video") { $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == true }
        try assertMovingVideo()
        let s=snapshot()
        app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:number(s,"expandX"),dy:number(s,"expandY"))).tap()
        _ = try waitFor("Expand before paused swipe with native controls hidden") { state in
            let native = state["nativePlayer"] as? [String: Any] ?? [:]
            return state["minimized"] as? Bool == false &&
                (native["active"] as? Bool != true || state["controlsVisible"] as? Bool == false)
        }
        try tapWebButton("Pause video")
        _ = try waitFor("Pause before swipe") { $0["videoPlaying"] as? Bool == false }
        videoPoint(0.5,0.28).press(forDuration: 0.05, thenDragTo: videoPoint(0.5,0.85))
        _ = try waitFor("Swipe must minimize paused video") { $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == false }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(snapshot()["videoPlaying"] as? Bool ?? true); evidence("swipe-minimize")
    }

    func testNativeControlsHideAndReturnOnTap() throws {
        try openSample()
        let opened = try waitFor("Native video starts without overlaid controls", timeout: 12) { state in
            let native = state["nativePlayer"] as? [String: Any] ?? [:]
            return native["active"] as? Bool == true &&
                native["mode"] as? String == "video" &&
                native["controlsVisible"] as? Bool == false
        }
        let initial = opened["nativePlayer"] as? [String: Any] ?? [:]
        try assertMovingVideo()
        videoPoint(0.5, 0.25).tap()
        _ = try waitFor("Picture tap reveals controls without cancelling play intent", timeout: 8) { s in
            let n = s["nativePlayer"] as? [String:Any] ?? [:]
            return s["controlsVisible"] as? Bool == true && n["playRequested"] as? Bool == true
        }
        // Streaming can briefly buffer during this tap; demand actual new
        // decoded frames and a moving clock, not just a saved play flag.
        try assertMovingVideo()
        _ = try waitFor("Playing controls hide after eight seconds", timeout: 12) {
            $0["controlsVisible"] as? Bool == false && $0["videoPlaying"] as? Bool == true
        }
        evidence("native-controls-hidden")
        videoPoint(0.5, 0.25).tap()
        let revealed = try waitFor("A picture tap restores controls without pausing", timeout: 5) {
            $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true
        }
        let same = revealed["nativePlayer"] as? [String: Any] ?? [:]
        XCTAssertEqual(number(initial, "itemEpoch"), number(same, "itemEpoch"))
        XCTAssertGreaterThan(number(same, "position"), number(initial, "position"))
        evidence("native-controls-revealed")
        try tapWebButton("Pause video")
        _ = try waitFor("Video pauses without losing its position", timeout: 5) {
            $0["videoPlaying"] as? Bool == false
        }
        let paused = number(snapshot(), "videoTime")
        _ = try waitFor("Paused controls also auto-hide after eight seconds", timeout: 12) {
            $0["controlsVisible"] as? Bool == false && $0["videoPlaying"] as? Bool == false
        }
        XCTAssertEqual(number(snapshot(), "videoTime"), paused, accuracy: 0.3)
        evidence("native-paused-controls-hidden")
        videoPoint(0.5, 0.25).tap()
        _ = try waitFor("Tap reveals paused controls without playing", timeout: 5) {
            $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == false
        }
        XCTAssertEqual(number(snapshot(), "videoTime"), paused, accuracy: 0.3)
    }

    func testSwipeBelowVideoMinimizesPlayingAndPausedNativeItem() throws {
        try openSample(); try assertMovingVideo()
        for paused in [false, true] {
            if paused {
                let mini = snapshot()
                app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: number(mini,"expandX"), dy: number(mini,"expandY"))).tap()
                _ = try waitFor("Expand before details swipe") { $0["minimized"] as? Bool == false }
                try tapWebButton("Pause video")
                _ = try waitFor("Pause before details swipe") { $0["videoPlaying"] as? Bool == false }
            }
            let before = try waitFor("Visible heading below video for physical swipe") {
                self.number($0,"detailsSwipeEndY") - self.number($0,"detailsSwipeY") >= 110 &&
                self.number($0,"watchScrollTop") <= 3
            }
            let native = before["nativePlayer"] as? [String: Any] ?? [:]
            let origin = app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: number(before,"detailsSwipeX"),dy: number(before,"detailsSwipeY")))
            let end = origin.withOffset(CGVector(dx: number(before,"detailsSwipeX"),dy: number(before,"detailsSwipeEndY")))
            start.press(forDuration: 0.05, thenDragTo: end)
            let after = try waitFor("Swipe below picture minimizes existing item", timeout: 10) {
                $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == !paused
            }
            let current = after["nativePlayer"] as? [String: Any] ?? [:]
            XCTAssertEqual(number(current,"itemEpoch"), number(native,"itemEpoch"))
            XCTAssertEqual(current["id"] as? String, native["id"] as? String)
            XCTAssertEqual(number(current,"rate"), number(native,"rate"))
            if paused { XCTAssertEqual(number(current,"position"), number(native,"position"), accuracy: 0.3) }
            else { XCTAssertGreaterThanOrEqual(number(current,"position"), number(native,"position") - 0.3) }
            evidence(paused ? "details-swipe-paused" : "details-swipe-playing")
        }
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
        let expanded = try waitFor("Expanded player keeps controls hidden until tapped") { state in
            let native = state["nativePlayer"] as? [String: Any] ?? [:]
            return state["minimized"] as? Bool == false &&
                (native["active"] as? Bool != true || state["controlsVisible"] as? Bool == false)
        }
        try assertMovingVideo()
        if expanded["controlsVisible"] as? Bool != true {
            videoPoint(0.5, 0.25).tap()
            _ = try waitFor("Tap after expansion reveals controls without pausing") {
                $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true
            }
        }
        evidence("expanded-video")
    }

    func testPictureInPictureAndReopenKeepsControlsHiddenUntilTap() throws {
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
        _ = try waitFor("Reopen from PiP restores inline video with native controls hidden",timeout:50) { s in
            let n=s["nativePlayer"] as? [String:Any] ?? [:]
            return s["pip"] as? Bool == false && s["videoVisible"] as? Bool == true &&
                (!isNative || s["controlsVisible"] as? Bool == false) &&
                (!isNative || (n["mode"] as? String == "video" &&
                               n["layerReady"] as? Bool == true &&
                               n["pipActive"] as? Bool == false))
        }
        try assertMovingVideo()
        if isNative {
            videoPoint(0.5, 0.25).tap()
            _ = try waitFor("Tap after PiP reveals controls without interrupting playback", timeout: 5) {
                $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true
            }
        }
        evidence("pip-reopen")
    }


}
