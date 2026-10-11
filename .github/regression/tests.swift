
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
        // A saved session may finish restoring asynchronously AFTER the
        // initial loggedIn snapshot. Do not demand a login form if the server
        // just authenticated the real dedicated account in the meantime.
        try regressionWait("Account must load either login or restored profile", timeout: 60) {
            $0["loginForm"] as? Bool == true ||
            ($0["loggedIn"] as? Bool == true && $0["authenticatedProfile"] as? Bool == true)
        }
        if regression()["loggedIn"] as? Bool == true {
            let restored=(snapshot()["account"] as? [String:Any])?["accountEmail"] as? String ?? ""
            XCTAssertEqual(restored.lowercased(),email.lowercased(),
                           "Asynchronously restored session belongs to wrong user")
            XCTAssertFalse(regression()["isAdmin"] as? Bool ?? true,
                           "Do not use an administrator account for simulator QA")
            return
        }
        try regressionEnter("loginEmail",email)
        let submittedBefore = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        try regressionEnter("loginPassword",password)
        // WebKit's native Go/Return may have submitted already. A second
        // login tap must NOT duplicate the in-flight POST or race a render.
        let submittedAfter = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        if submittedAfter <= submittedBefore && regression()["loggedIn"] as? Bool != true {
            try regressionTap("loginSubmit")
        }
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
        let success = done.wait(timeout: .now() + 15) == .success
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
        // An xcrun simctl push is accepted even if the user has never granted
        // alerts. First exercise the actual native iOS permission dialogue.
        // The test-only button requests OS authorization; XCTest performs the
        // tap, and an independent native notification-settings query confirms it.
        let enable = app.buttons["ist-simulator-enable-push"]
        XCTAssertTrue(enable.waitForExistence(timeout: 12),
                      "Native push permission control must be in the simulator build")
        enable.tap()
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let systemAllow=springboard.alerts.buttons["Allow"].firstMatch
        let appAllow=app.alerts.buttons["Allow"].firstMatch
        if systemAllow.waitForExistence(timeout: 8) {
            systemAllow.tap()
        } else if appAllow.exists {
            appAllow.tap()
        }
        _ = try waitFor("Real iOS notification authorization is granted",timeout:30) {
            $0["nativePushAuthorized"] as? Bool == true
        }
        try regressionActivateSample()
        // workflow sends a REAL xcrun simctl push via SpringBoard while Home
        // is in the foreground; no direct app.activate() shortcut is allowed.
        let initial=regression()["pushActions"] as? Int ?? 0
        XCUIDevice.shared.press(.home)
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

    // iOS 26 WebKit can present <select> either as a traditional picker wheel
    // or as a native popover list. Both paths tap the actual native option.
    // We then assert the real HTMLVideoElement playbackRate, never a stub.
    private func chooseRealVideoSpeed(_ label: String) throws {
        // Native iOS WebKit hides some <select> options from accessibility.
        // If present, use the app's REAL accessible speed buttons, then
        // independently assert video.playbackRate in the subsequent test.
        let controls = regression()["controls"] as? [String:[String:Any]] ?? [:]
        if controls["videoSpeedToggle"] != nil {
            try regressionTap("videoSpeedToggle")
            let key = label == "1.5x" ? "videoSpeed15" : "videoSpeed10"
            try regressionWait("Real speed choice is visible and hit-tested", timeout: 15) {
                let choices = $0["controls"] as? [String:[String:Any]] ?? [:]
                return choices[key] != nil
            }
            try regressionTap(key)
            return
        }
        try regressionTap("videoSpeed")
        let wheel = app.pickerWheels.firstMatch
        if wheel.waitForExistence(timeout: 3) {
            wheel.adjust(toPickerWheelValue: label)
        } else {
            let option = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard option.waitForExistence(timeout: 12) && option.isHittable else {
                evidence("missing-native-speed-option-" + label)
                XCTFail("Native iOS speed menu does not expose the real " + label + " option")
                throw Failure.timedOut("Native speed choice " + label)
            }
            option.tap()
        }
        regressionKeyboardDone()
    }

    func testRegressionSpeedDefaultAndOnePointFiveAfterReopen() throws {
        try regressionActivateSample()
        // Another genuine test can leave a 1.5x speed preference in the
        // simulator. Restore 1x through the real UI before testing defaults.
        if abs(number(snapshot(),"speed")-1) > 0.01 {
            try chooseRealVideoSpeed("1x")
            try regressionWait("Reset persisted playback preference using native UI") {
                abs(self.number($0,"videoRate")-1)<0.02 &&
                abs(self.number($0,"configuredAudioRate")-1)<0.02
            }
        }
        XCTAssertEqual(number(snapshot(),"speed"),1,accuracy:0.01,
                       "Video must play at 1x after the user selects 1x")
        try chooseRealVideoSpeed("1.5x")
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
        try tapWebButton("Audio")
        _ = try waitFor("Audio inherits chosen 1.5x speed and keeps playing",timeout:60) {
            $0["mode"] as? String == "audio" && $0["audioPlaying"] as? Bool == true &&
            abs(self.number($0,"speed")-1.5)<0.02
        }
        try tapWebButton("Video")
        _ = try waitFor("Video restores chosen speed after switching back",timeout:90) {
            $0["mode"] as? String == "video" && $0["videoPlaying"] as? Bool == true &&
            $0["audioPlaying"] as? Bool == false &&
            abs(self.number($0,"speed")-1.5)<0.02
        }
        try regressionVideoMoving()
        try chooseRealVideoSpeed("1x")
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
        // XCUITest provides no public .lock button (only Home, volume, etc.).
        // Use the simulator-only XCUIDevice lock selector, verify it genuinely
        // backgrounds the app, and fail if this Xcode runtime lacks it.
        let lockSelector = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lockSelector) else {
            XCTFail("Native simulator lock API unavailable; real lock test cannot run")
            throw Failure.timedOut("Simulator lock button")
        }
        XCUIDevice.shared.perform(lockSelector)
        let springboard = XCUIApplication(bundleIdentifier:"com.apple.springboard")
        _ = try waitFor("The device must leave the app after genuine screen lock", timeout: 15) { _ in
            self.app.state != .runningForeground
        }
        Thread.sleep(forTimeInterval:12)
        XCUIDevice.shared.perform(lockSelector)
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

    private func regressionHistoryPostCount() -> Int {
        let all=(snapshot()["account"] as? [String:Any])?["requests"] as? [[String:Any]] ?? []
        return all.filter { $0["path"] as? String == "/history" && $0["ok"] as? Bool == true }.count
    }

    func testRegressionOfflineDownloadPlaysWithoutNetworkAndSyncsHistory() throws {
        try regressionLogin()
        try regressionActivateSample()
        if regression()["offlineSaved"] as? Bool != true {
            try regressionTap("offlineSave")
        }
        try regressionWait("Native file transfer downloads a real nonempty audio file",timeout:180) {
            $0["offlineSaved"] as? Bool == true && self.number($0,"offlineBytes")>1024 &&
            self.number($0,"offlineJobs")==0
        }
        // Leave the watch overlay through its actual Back button and launch the
        // downloaded item from the real Library > Downloads row.
        try regressionTap("closeWatch")
        try regressionTap("library")
        try regressionTap("downloads")
        try regressionWait("Downloaded real file is listed on Downloads page") {
            let controls=$0["controls"] as? [String:[String:Any]] ?? [:]
            return controls["offlinePlay"] != nil
        }
        try regressionWait("API works before forced offline state") { $0["online"] as? Bool == true }
        try regressionNetwork("DOWN")
        defer { try? regressionNetwork("UP") }
        try regressionWait("Real API probe fails during simulated network outage",timeout:30) {
            $0["online"] as? Bool == false && $0["networkProbeFailed"] as? Bool == true
        }
        try regressionTap("offlinePlay")
        let playing=try waitFor("Saved native audio file plays while external network is blocked",timeout:60) {
            let reg=$0["regression"] as? [String:Any] ?? [:]
            return reg["offlineCurrent"] as? Bool == true &&
                reg["playingAudio"] as? Bool == true &&
                reg["online"] as? Bool == false &&
                self.number($0,"audioTime")>1
        }
        let at=number(playing,"audioTime")
        _ = try waitFor("Offline audio clock keeps advancing without server access",timeout:45) {
            let reg=$0["regression"] as? [String:Any] ?? [:]
            return reg["offlineCurrent"] as? Bool == true &&
                reg["playingAudio"] as? Bool == true &&
                self.number($0,"audioTime")>at+3
        }
        let historyBefore=regressionHistoryPostCount()
        try regressionNetwork("UP")
        try regressionWait("Real API connectivity restored after offline playback",timeout:45) {
            $0["online"] as? Bool == true
        }
        try regressionTap("playFull")
        try regressionTap("watchFromAudio")
        _ = try waitFor("Real playback history gets a successful server write after reconnect",timeout:90) {
            let requests=($0["account"] as? [String:Any])?["requests"] as? [[String:Any]] ?? []
            return requests.filter { $0["path"] as? String == "/history" &&
                $0["ok"] as? Bool == true }.count > historyBefore
        }
        _ = try waitFor("Return to video removes competing HTML audio",timeout:80) {
            $0["mode"] as? String == "video" && $0["videoPlaying"] as? Bool == true &&
            $0["audioPlaying"] as? Bool == false
        }
        try regressionVideoMoving()
    }

    func testRegressionLoginErrorServerRevocationNameAndRelogin() throws {
        let env=ProcessInfo.processInfo.environment
        guard let email=env["IRGUN_TEST_EMAIL"],let pass=env["IRGUN_TEST_PASSWORD"],
              !email.isEmpty && !pass.isEmpty else {
            XCTFail("Require secrets for native invalid-password exercise")
            throw Failure.timedOut("account secrets")
        }
        if regression()["loggedIn"] as? Bool == true {
            try regressionTap("account")
            try regressionTap("logout")
            try regressionWait("Start from logged-out native state") {
                $0["loggedIn"] as? Bool == false
            }
        }
        try regressionTap("account")
        try regressionWait("Sign-in form is native visible") { $0["loginForm"] as? Bool == true }
        try regressionEnter("loginEmail",email)
        let invalidSubmitBefore = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        try regressionEnter("loginPassword",pass+"not-valid")
        if number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount") <= invalidSubmitBefore {
            try regressionTap("loginSubmit")
        }
        try regressionWait("Wrong password must return visible error and never create a session",timeout:60) {
            $0["loggedIn"] as? Bool == false &&
            $0["loginError"] as? Bool == true &&
            $0["loginBusy"] as? Bool == false
        }
        // The wrong-password response must retain a valid email field so the
        // user can correct only their password through the real native form.
        let errorForm = snapshot()["account"] as? [String:Any] ?? [:]
        XCTAssertEqual(number(errorForm,"authEmailLength"),Double(email.count),
                       "Wrong-password error must preserve the email address")
        XCTAssertEqual(errorForm["authEmailValid"] as? Bool,true,
                       "Email address must remain a valid native email input")
        let retrySubmitBefore = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        try regressionEnter("loginPassword",pass)
        if number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount") <= retrySubmitBefore &&
           regression()["loggedIn"] as? Bool != true {
            try regressionTap("loginSubmit")
        }
        try regressionWait("Valid login succeeds after bad password",timeout:90) {
            $0["loggedIn"] as? Bool == true && $0["authenticatedProfile"] as? Bool == true
        }
        XCTAssertEqual(
            String((snapshot()["account"] as? [String:Any])?["accountEmail"] as? String ?? "")
                .lowercased(),email.lowercased(),"Do not mutate another user's account"
        )
        let before=regression()["accountName"] as? String ?? ""
        XCTAssertFalse(before.isEmpty,"QA account must have a stored name")
        let temporary="Irgun QA Name \(Int(Date().timeIntervalSince1970))"
        try regressionEnter("profileName",temporary)
        try regressionTap("profileSave")
        try regressionWait("Real profile save must update the current signed-in identity",timeout:60) {
            $0["accountName"] as? String == temporary
        }
        app.terminate();app.launch()
        try regressionWait("Name edit survives native relaunch and server profile reload",timeout:90) {
            $0["loggedIn"] as? Bool == true && $0["accountName"] as? String == temporary
        }
        try regressionTap("account")
        try regressionWait("Profile field reflects stored renamed value") {
            $0["profileName"] as? String == temporary && $0["profileNameShown"] as? String == temporary
        }
        try regressionEnter("profileName",before)
        try regressionTap("profileSave")
        try regressionWait("Original QA account name restored") { $0["accountName"] as? String == before }
        app.terminate();app.launch()
        try regressionWait("Server still stores original restored name",timeout:90) {
            $0["loggedIn"] as? Bool == true && $0["accountName"] as? String == before
        }
        try regressionTap("account")
        try regressionTap("invalidateQA")
        try regressionWait("Real Worker logout invalidates the server session") {
            $0["serverRevoked"] as? Bool == true
        }
        // The simulator app deliberately still retains its old token locally.
        // A cold launch now exercises production /me => 401 => signed-out UI.
        XCTAssertEqual(regression()["accountTokenPresent"] as? Bool,true)
        app.terminate();app.launch()
        try regressionWait("Server-invalidated session clears login and account data",timeout:90) {
            $0["loggedIn"] as? Bool == false && $0["accountTokenPresent"] as? Bool == false
        }
        try regressionLogin()
        try regressionWait("Account name survives revoked-session reauthentication") {
            $0["accountName"] as? String == before
        }
        try regressionTap("logout")
        try regressionWait("Normal logout clears authenticated state") {
            $0["loggedIn"] as? Bool == false && $0["accountTokenPresent"] as? Bool == false
        }
        try regressionLogin()
        try regressionWait("Signing in again after logout restores correct saved name") {
            $0["loggedIn"] as? Bool == true && $0["accountName"] as? String == before
        }
    }

    // Cross-device job executes writer on a fresh iPhone simulator and reader
    // on an independently installed iPad using the same dedicated account.
    // The observer reads actual server-loaded collections from each device.
    private func regressionSyncName() throws -> String {
        guard let marker=ProcessInfo.processInfo.environment["IRGUN_SYNC_MARKER"],
              !marker.isEmpty else {
            XCTFail("Shared deterministic QA sync marker missing")
            throw Failure.timedOut("sync marker")
        }
        return "IST-IOS-SYNC-"+marker
    }

    func testRegressionCrossDeviceWriterOnIPhone() throws {
        let name=try regressionSyncName()
        try regressionLogin()
        try regressionTap("shiurim")
        try regressionTap("open")
        try regressionWait("Writer opens real server lecture and account UI") {
            !String($0["currentId"] as? String ?? "").isEmpty
        }
        // Force known state ON, but do not toggle when already ON.
        if regression()["likedCurrent"] as? Bool != true {
            try regressionTap("like")
            try regressionWait("Writer like saved") { $0["likedCurrent"] as? Bool == true }
        }
        if regression()["speakerFollowActive"] as? Bool != true {
            try regressionTap("follow")
            try regressionWait("Writer speaker follow saved") {
                $0["speakerFollowActive"] as? Bool == true
            }
        }
        try regressionTap("closeWatch")
        try regressionTap("library")
        try regressionTap("playlists")
        if !(regression()["syncPlaylistNames"] as? [String] ?? []).contains(name) {
            try regressionTap("playlistName")
            let field=app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout:8))
            field.typeText(name+"\n")
        }
        try regressionWait("Writer created playlist stored in authenticated account",timeout:90) {
            ($0["syncPlaylistNames"] as? [String] ?? []).contains(name)
        }
        XCTAssertEqual(regression()["loggedIn"] as? Bool,true)
    }

    func testRegressionCrossDeviceReaderOnIPad() throws {
        let name=try regressionSyncName()
        try regressionLogin()
        try regressionWait("Independent iPad session fetched iPhone-created playlist") {
            ($0["syncPlaylistNames"] as? [String] ?? []).contains(name)
        }
        try regressionTap("shiurim")
        try regressionTap("open")
        try regressionWait("Independent iPad sees like and speaker follow written on iPhone") {
            $0["likedCurrent"] as? Bool == true &&
            $0["speakerFollowActive"] as? Bool == true
        }
        XCTAssertEqual(regression()["isAdmin"] as? Bool,false)
    }
