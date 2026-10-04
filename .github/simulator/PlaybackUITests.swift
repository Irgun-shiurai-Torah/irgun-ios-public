import XCTest

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
        let label = app.staticTexts["ist-simulator-status"]
        guard label.exists, let value = label.value as? String,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
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
        Thread.sleep(forTimeInterval: 6)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "home-during-playback"
        home.lifetime = .keepAlways
        add(home)
        app.activate()
        _ = try waitFor("Reopen must resume video beyond the pre-Home position", timeout: 60) {
            $0["mode"] as? String == "video" && $0["ready"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true && self.number($0, "videoTime") >= before + 3
        }
        try assertMovingVideo()
        evidence("home-reopen")
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
