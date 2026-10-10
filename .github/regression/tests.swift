
    // Added only to disposable iOS simulator test builds by regression/prepare.py.
    // The shared snapshot/waitFor/openSample/assertMovingVideo methods are used,
    // so media and account checks inspect the same real app as existing suites.
    private func regression() -> [String: Any] {
        snapshot()["regression"] as? [String: Any] ?? [:]
    }

    private func regressionWait(_ message: String, timeout: TimeInterval = 45,
                                _ check: @escaping ([String:Any]) -> Bool) throws {
        _ = try waitFor(message, timeout: timeout) {
            guard let reg = $0["regression"] as? [String:Any] else { return false }
            return check(reg)
        }
    }

    private func regressionTap(_ key: String) throws {
        let diagnostics = app.buttons["ist-simulator-hide-controls"]
        if diagnostics.exists && diagnostics.isHittable { diagnostics.tap() }
        for _ in 0..<9 {
            let snap=regression()
            let controls=snap["controls"] as? [String: [String:Any]] ?? [:]
            if let point=controls[key] {
                app.webViews.firstMatch.coordinate(withNormalizedOffset:.zero)
                    .withOffset(CGVector(dx:number(point,"x"),dy:number(point,"y"))).tap()
                return
            }
            let rects=snap["rects"] as? [String:[String:Any]] ?? [:]
            if rects[key] == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            } else if number(rects[key] ?? [:],"y") < 0 {
                app.webViews.firstMatch.swipeDown()
            } else {
                app.webViews.firstMatch.swipeUp()
            }
        }
        XCTFail("Native control not available or not hittable: \(key)")
        throw Failure.timedOut(key)
    }

    private func regressionKeyboardDone() {
        guard app.keyboards.firstMatch.exists else { return }
        let done=app.buttons["Done"].firstMatch
        if done.exists && done.isHittable { done.tap(); return }
        for label in ["Done","Return","Go","Log In"] {
            let btn=app.keyboards.buttons[label].firstMatch
            if btn.exists && btn.isHittable { btn.tap(); return }
        }
    }

    private func regressionEnter(_ key: String, _ text: String) throws {
        try regressionTap(key)
        let field=key=="loginPassword" ? app.secureTextFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Native keyboard field \(key) missing")
        let old=(field.value as? String ?? "")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: max(old.count,text.count)+9))
        field.typeText(text)
        regressionKeyboardDone()
    }

    private func regressionLogin() throws {
        let env=ProcessInfo.processInfo.environment
        guard let email=env["IRGUN_TEST_EMAIL"],let password=env["IRGUN_TEST_PASSWORD"],
              !email.isEmpty && !password.isEmpty else {
            XCTFail("Dedicated account credentials must be supplied as Actions secrets")
            throw Failure.timedOut("QA credentials")
        }
        if regression()["loggedIn"] as? Bool == true {
            try regressionTap("account")
            try regressionWait("QA identity must be authenticated") { s in
                s["authenticatedProfile"] as? Bool == true
            }
            XCTAssertEqual(
                String((snapshot()["account"] as? [String:Any])?["accountEmail"] as? String ?? "")
                    .lowercased(),email.lowercased(),"Incorrect dedicated QA identity"
            )
            return
        }
        try regressionTap("account")
        try regressionWait("Actual email/password form appears") { $0["loginForm"] as? Bool == true }
        try regressionEnter("loginEmail",email)
        try regressionEnter("loginPassword",password)
        if regression()["loggedIn"] as? Bool != true { try regressionTap("loginSubmit") }
        try regressionWait("Server accepted dedicated QA account",timeout:90) {
            $0["loggedIn"] as? Bool == true && $0["authenticatedProfile"] as? Bool == true
        }
        let observed=(snapshot()["account"] as? [String:Any])?["accountEmail"] as? String ?? ""
        XCTAssertEqual(observed.lowercased(),email.lowercased(),"Wrong authenticated account")
        XCTAssertFalse(regression()["isAdmin"] as? Bool ?? true,"Do not edit admin accounts in QA")
    }

    // Host-side macOS PF gate is independently verified by real /auth-config
    // requests in the app's WKWebView. No navigator.onLine or fake offline state.
    private func regressionNetwork(_ command: String) throws {
        let connection=NWConnection(host:"127.0.0.1",port:47311,using:.tcp)
        let queue=DispatchQueue(label:"org.irgun.regression.network-gate")
        let done=DispatchSemaphore(value:0)
        let lock=NSLock()
        var answer=""
        connection.stateUpdateHandler = { state in
            if case .ready=state {
                connection.send(content:Data((command+"\n").utf8),completion:.contentProcessed{ _ in
                    connection.receive(minimumIncompleteLength:1,maximumLength:1024) { data,_,_,_ in
                        lock.lock();answer=String(data:data ?? Data(),encoding:.utf8) ?? "";lock.unlock()
                        done.signal()
                    }
                })
            } else if case .failed=state { done.signal() }
        }
        connection.start(queue:queue)
        let success=done.wait(timeout:.now()+15)==.success
        connection.cancel()
        lock.lock();let received=answer;lock.unlock()
        XCTAssertTrue(success && received.hasPrefix("OK:"+command),
                      "Host packet filter did not acknowledge \(command). Do not fake network tests.")
        if !success || !received.hasPrefix("OK:"+command) {
            throw Failure.timedOut("Real network gate \(command)")
        }
    }

    private func regressionVideoMoving() throws {
        try assertMovingVideo()
        let s=snapshot()
        XCTAssertEqual(number(s,"playerCount"),1,"Must have exactly one video player")
        XCTAssertEqual(s["audioPlaying"] as? Bool,false,"HTML audio must not play simultaneously")
    }

    private func regressionActivateSample() throws {
        try openSample()
        try regressionVideoMoving()
        try regressionWait("Video lecture must support its audio counterpart") {
            $0["hasAudio"] as? Bool == true
        }
    }

    func testRegressionBackgroundAudioAndReopenControls() throws {
        try regressionActivateSample()
        let t=number(snapshot(),"videoTime")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval:16)
        app.activate()
        let resumed=try waitFor("Background native audio clock must really progress",timeout:70) {
            let native=$0["nativeAudio"] as? [String:Any] ?? [:]
            let samples=native["backgroundSamples"] as? [Double] ?? []
            return samples.count>=3 && (samples.last ?? 0)-(samples.first ?? 0)>3 &&
                   $0["videoPlaying"] as? Bool == true && $0["controlsVisible"] as? Bool == true &&
                   self.number($0,"videoTime")>t+3
        }
        XCTAssertEqual(number(resumed,"playerCount"),1)
        try tapWebButton("Pause video")
        _ = try waitFor("Pause after background return works") {
            $0["videoPlaying"] as? Bool == false
        }
        try tapWebButton("Play video")
        try regressionVideoMoving()
    }

    func testRegressionNotificationTapRestoresInlinePlayer() throws {
        try regressionActivateSample()
        // workflow sends a REAL xcrun simctl push via SpringBoard while Home
        // is in the foreground; no direct app.activate() shortcut is allowed.
        let initial=regression()["pushActions"] as? Int ?? 0
        XCUIDevice.shared.press(.home)
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let notification=springboard.descendants(matching:.any)
            .matching(NSPredicate(format:"label CONTAINS %@", "Irgun QA Playback")).firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout:65),
                      "Simulator notification must really appear in SpringBoard")
        XCTAssertTrue(notification.isHittable,"Simulated push must be tappable")
        notification.tap()
        try regressionWait("Notification action must reach the app's native listener",timeout:45) {
            ($0["pushActions"] as? Int ?? 0)>initial &&
            $0["pushWatchTarget"] as? Bool == true
        }
        _ = try waitFor("Notification reopening restores inline player controls",timeout:75) {
            $0["mode"] as? String == "video" && $0["pip"] as? Bool == false &&
            $0["videoVisible"] as? Bool == true && $0["controlsVisible"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true && self.number($0,"playerCount")==1
        }
        try tapWebButton("Pause video")
        _ = try waitFor("Pause works after notification launch") {
            $0["videoPlaying"] as? Bool == false
        }
        try tapWebButton("Play video")
        try regressionVideoMoving()
    }

    func testRegressionMiniFullscreenPiPCycle() throws {
        try regressionActivateSample()
        let prior=number(snapshot(),"videoTime")
        try tapWebButton("Fullscreen")
        _ = try waitFor("Native fullscreen opens") { $0["fullscreen"] as? Bool == true }
        try regressionVideoMoving()
        try tapWebButton("Exit Fullscreen")
        _ = try waitFor("Return from fullscreen keeps real video") {
            $0["fullscreen"] as? Bool == false && $0["videoPlaying"] as? Bool == true
        }
        try tapWebButton("Keep playing at bottom of app")
        _ = try waitFor("Minimised video keeps playing") {
            $0["minimized"] as? Bool == true && $0["videoPlaying"] as? Bool == true
        }
        let mini=snapshot(),x=number(mini,"expandX"),y=number(mini,"expandY")
        XCTAssertGreaterThan(x,0);XCTAssertGreaterThan(y,0)
        app.webViews.firstMatch.coordinate(withNormalizedOffset:.zero)
            .withOffset(CGVector(dx:x,dy:y)).tap()
        _ = try waitFor("Expand must restore controls") {
            $0["minimized"] as? Bool == false && $0["controlsVisible"] as? Bool == true
        }
        XCTAssertEqual(number(snapshot(),"playerCount"),1)
        XCTAssertTrue(snapshot()["pipSupported"] as? Bool == true,
                      "PiP unsupported on chosen simulator; this scenario cannot be marked passed")
        try tapWebButton("Picture in Picture")
        _ = try waitFor("PiP genuinely enters",timeout:40) { $0["pip"] as? Bool == true }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval:5)
        app.activate()
        _ = try waitFor("PiP return must restore inline controls",timeout:60) {
            $0["pip"] as? Bool == false && $0["minimized"] as? Bool == false &&
            $0["videoVisible"] as? Bool == true &&
            $0["controlsVisible"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true &&
            self.number($0,"videoTime")>prior &&
            self.number($0,"playerCount")==1
        }
        try regressionVideoMoving()
    }

    func testRegressionNetworkLossAndRecovery() throws {
        try regressionActivateSample()
        try regressionWait("API network really online before disruption",timeout:30) {
            $0["online"] as? Bool == true &&
            Date().timeIntervalSince1970*1000-self.number($0,"networkCheckedAt")<7000
        }
        let t=number(snapshot(),"videoTime")
        try regressionNetwork("DOWN")
        defer { try? regressionNetwork("UP") }
        try regressionWait("Actual live HTTP request fails while external networking is blocked",timeout:30) {
            $0["online"] as? Bool == false && $0["networkProbeFailed"] as? Bool == true
        }
        // Buffered media may continue without a network: that is legitimate.
        XCTAssertEqual(snapshot()["mode"] as? String,"video")
        try regressionNetwork("UP")
        try regressionWait("API live HTTP request recovers after reconnect",timeout:40) {
            $0["online"] as? Bool == true
        }
        _ = try waitFor("Video resumes from saved position after network returns",timeout:90) {
            $0["videoPlaying"] as? Bool == true &&
            $0["videoVisible"] as? Bool == true &&
            self.number($0,"videoTime")>=max(0,t-3) &&
            self.number($0,"playerCount")==1
        }
        try regressionVideoMoving()
    }

    func testRegressionSpeedDefaultAndOnePointFiveAfterReopen() throws {
        try regressionActivateSample()
        XCTAssertEqual(number(snapshot(),"speed"),1,accuracy:0.01,
                       "Fresh simulator playback must start at 1x")
        // Selecting this actual native <select> through XCTest is not a
        // JavaScript setter. WebKit should display the iOS picker.
        try regressionTap("videoSpeed")
        let picker=app.pickerWheels.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout:10),"iOS speed select must open picker")
        picker.adjust(toPickerWheelValue:"1.5x")
        regressionKeyboardDone()
        try regressionWait("Native speed selection updates real video playback rate") {
            abs(self.number($0,"videoRate")-1.5)<0.02
        }
        app.terminate()
        app.launch()
        try regressionWait("Session restored after player speed change",timeout:90) {
            $0["online"] as? Bool == true
        }
        try regressionActivateSample()
        XCTAssertEqual(number(snapshot(),"speed"),1.5,accuracy:0.02,
                       "User-selected speed should survive app relaunch")
        XCTAssertEqual(number(regression(),"videoSpeedChoice"),1.5,accuracy:0.02)
        try regressionVideoMoving()
        try regressionTap("videoSpeed")
        let reset=app.pickerWheels.firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout:10))
        reset.adjust(toPickerWheelValue:"1x")
        regressionKeyboardDone()
        try regressionWait("Speed restored to 1x after QA") {
            abs(self.number($0,"videoRate")-1)<0.02
        }
    }

    func testRegressionHebrewRtlAndVisibleControls() throws {
        try regressionWait("Initial app language is English") { $0["language"] as? String == "en" }
        try regressionTap("language")
        try regressionWait("Language control changes actual document direction") {
            $0["language"] as? String == "he" && $0["documentDir"] as? String == "rtl" &&
            $0["rtlToggleLabel"] as? String == "English"
        }
        let nav=regression()["bottomNav"] as? [[String:Any]] ?? []
        XCTAssertGreaterThanOrEqual(nav.count,4)
        XCTAssertTrue(nav.allSatisfy { $0["within"] as? Bool == true },
                      "Hebrew RTL bottom navigation must fit within viewport")
        XCTAssertTrue(nav.contains {
            String($0["label"] as? String ?? "").unicodeScalars.contains {
                (0x0590...0x05ff).contains(Int($0.value))
            }
        },"At least one actual Hebrew nav label must render")
        try regressionTap("shiurim")
        _ = try waitFor("Hebrew shiurim page is interactive") {
            $0["screen"] as? String == "shiurim"
        }
        try regressionTap("language")
        try regressionWait("Return to normal LTR English works") {
            $0["documentDir"] as? String == "ltr" && $0["language"] as? String == "en"
        }
    }

    func testRegressionLongPlaybackLockAndModeChanges() throws {
        try regressionActivateSample()
        let start=number(snapshot(),"videoTime")
        // Check repeatedly for three minutes, not just a single advancing tick.
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval:15)
            let s=snapshot()
            XCTAssertEqual(s["videoPlaying"] as? Bool,true)
            XCTAssertEqual(number(s,"playerCount"),1)
            XCTAssertEqual(s["audioPlaying"] as? Bool,false)
        }
        XCTAssertGreaterThan(number(snapshot(),"videoTime"),start+90,
                             "Video must sustain playback beyond a brief startup")
        XCUIDevice.shared.press(.lock)
        Thread.sleep(forTimeInterval:12)
        XCUIDevice.shared.press(.lock)
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        springboard.swipeUp()
        app.activate()
        _ = try waitFor("Player survives real lock/unlock",timeout:70) {
            $0["videoPlaying"] as? Bool == true && $0["controlsVisible"] as? Bool == true
        }
        try regressionVideoMoving()
        for _ in 0..<3 {
            let previous=number(snapshot(),"videoTime")
            try tapWebButton("Audio")
            let audio=try waitFor("Long-session mode switch gives active audio",timeout:70) {
                $0["mode"] as? String == "audio" && $0["audioPlaying"] as? Bool == true &&
                self.number($0,"audioTime")>=max(0,previous-3)
            }
            let audioTime=number(audio,"audioTime")
            try tapWebButton("Video")
            _ = try waitFor("Long-session return yields video only",timeout:90) {
                $0["mode"] as? String == "video" && $0["videoPlaying"] as? Bool == true &&
                $0["audioPlaying"] as? Bool == false && self.number($0,"playerCount")==1 &&
                self.number($0,"videoTime")>=max(0,audioTime-3)
            }
            try regressionVideoMoving()
        }
    }
