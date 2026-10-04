import XCTest
import Network

final class PlaybackUITests: XCTestCase {
    private var app: XCUIApplication!
    private enum Failure: Error { case timedOut(String) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "org.irgunshiuraitorah.app")
        app.launchArguments = ["--irgun-simulator-tests"]
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
        if ["Keep playing at bottom of app", "Picture in Picture"].contains(label) {
            let hide = app.buttons["ist-simulator-hide-controls"]
            if hide.exists && hide.isHittable { hide.tap() }
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
        // Retry only a missed harness tap, never an accepted/failed app open.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let state = snapshot()
            if state["opening"] as? Bool == true || !(state["id"] as? String ?? "").isEmpty || !(state["error"] as? String ?? "").isEmpty { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        let accepted = snapshot()
        if accepted["opening"] as? Bool != true && (accepted["id"] as? String ?? "").isEmpty && (accepted["error"] as? String ?? "").isEmpty { button.tap() }
    }

    private func openSample() throws {
        let button = app.buttons["ist-simulator-open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let state = try waitFor("HLS sample must start visibly", timeout: 150) {
            $0["mode"] as? String == "video" && $0["ready"] as? Bool == true &&
            $0["backend"] as? String == "hls-native" && $0["videoPlaying"] as? Bool == true &&
            $0["videoVisible"] as? Bool == true && self.number($0, "videoTime") >= 28
        }
        XCTAssertEqual(number(state, "speed"), 1, accuracy: 0.01)
        XCTAssertEqual(number(state, "playerCount"), 1, "Exactly one video element should exist")
        evidence("fresh-video")
    }

    private func assertMovingVideo() throws {
        let before = snapshot()
        XCTAssertTrue(before["frameApi"] as? Bool == true, "Simulator must expose video-frame callbacks")
        _ = try waitFor("Video frames and media clock must advance") {
            $0["videoPlaying"] as? Bool == true && $0["videoVisible"] as? Bool == true &&
            self.number($0, "frames") > self.number(before, "frames") + 2 &&
            self.number($0, "frameTime") > self.number(before, "frameTime") + 0.5 &&
            self.number($0, "videoTime") > self.number(before, "videoTime") + 0.5
        }
    }

    func testFreshVideoHasMovingFrames() throws {
        try openSample()
        try assertMovingVideo()
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
            self.number($0, "playerCount") == 1
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
            $0["mode"] as? String == "audio" && $0["audioPlaying"] as? Bool == true &&
            $0["pendingSeek"] as? Bool == false && self.number($0, "audioTime") >= videoTime - 2
        }
        evidence("watch-audio")
        let position = number(audio, "audioTime")
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
        let before = number(snapshot(), "videoTime")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 12)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "home-during-playback"
        home.lifetime = .keepAlways
        add(home)
        app.activate()
        let native = try waitFor("Native background samples must be available") {
            (($0["nativeAudio"] as? [String:Any])?["backgroundSamples"] as? [Double] ?? []).count >= 3
        }
        let samples = (native["nativeAudio"] as? [String:Any])?["backgroundSamples"] as? [Double] ?? []
        XCTAssertGreaterThan((samples.last ?? 0) - (samples.first ?? 0), 4, "Native clock must advance while UIApplication is backgrounded")
        _ = try waitFor("Reopen must resume video beyond the pre-Home position", timeout: 60) {
            $0["mode"] as? String == "video" && $0["ready"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true && self.number($0, "videoTime") >= before + 3
        }
        try assertMovingVideo()
        evidence("home-reopen")
    }

    private func videoPoint(_ x: Double, _ y: Double) -> XCUICoordinate {
        let s = snapshot()
        return app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: number(s,"videoX") + number(s,"videoWidth") * x,
            dy: number(s,"videoY") + number(s,"videoHeight") * y))
    }

    func testFullscreenExitKeepsPlayingAndPausedStaysPaused() throws {
        try openSample(); try assertMovingVideo()
        try tapWebButton("Fullscreen")
        _ = try waitFor("Fullscreen must open") { $0["fullscreen"] as? Bool == true }
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
        guard snapshot()["pipSupported"] as? Bool == true else {
            throw XCTSkip("This simulator runtime does not support WKWebView PiP; test on a real device")
        }
        try tapWebButton("Picture in Picture")
        _ = try waitFor("PiP must activate") { $0["pip"] as? Bool == true }
        evidence("pip-active")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        _ = try waitFor("Reopen from PiP must restore inline video and controls", timeout: 30) {
            $0["pip"] as? Bool == false && $0["videoVisible"] as? Bool == true &&
            $0["controlsVisible"] as? Bool == true
        }
        try assertMovingVideo()
        evidence("pip-reopen")
    }
}
