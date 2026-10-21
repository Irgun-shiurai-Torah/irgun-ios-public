
    // Added only to disposable iOS simulator test builds by regression/prepare.py.
    // The shared snapshot/waitFor/openSample/assertMovingVideo methods are used,
    // so media and account checks inspect the same real app as existing suites.
    private func regression() -> [String: Any] {
        snapshot()["regression"] as? [String: Any] ?? [:]
    }
    private func regressionSingleVideoOwner(_ s:[String:Any]) -> Bool {
        let n=s["nativePlayer"] as? [String:Any] ?? [:]
        if n["active"] as? Bool == true {
            return n["mode"] as? String == "video" && self.number(s,"playerCount") <= 1 &&
                s["audioPlaying"] as? Bool == false
        }
        return self.number(s,"playerCount") == 1 && s["audioPlaying"] as? Bool == false
    }
    private func regressionAudioIsPlaying(_ s:[String:Any]) -> Bool {
        let n=s["nativePlayer"] as? [String:Any] ?? [:]
        return n["active"] as? Bool == true && n["mode"] as? String == "audio"
            ? s["nativeAudioPlaying"] as? Bool == true
            : s["audioPlaying"] as? Bool == true
    }
    private func regressionAudioPosition(_ s:[String:Any]) -> Double {
        let n=s["nativePlayer"] as? [String:Any] ?? [:]
        return n["active"] as? Bool == true && n["mode"] as? String == "audio"
            ? self.number(s,"nativeAudioTime") : self.number(s,"audioTime")
    }

    private func regressionWait(_ message: String, timeout: TimeInterval = 45,
                                _ check: @escaping ([String:Any]) -> Bool) throws {
        _ = try waitFor(message, timeout: timeout) {
            guard let reg = $0["regression"] as? [String:Any] else { return false }
            return check(reg)
        }
    }

    private func regressionScroll(_ state: [String:Any], towardUp: Bool) {
        let reg = state["regression"] as? [String:Any] ?? state
        let width = number(reg,"width")
        let height = number(reg,"height")
        let native = state["nativePlayer"] as? [String:Any] ?? [:]
        let surfaceBottom = number(native,"surfaceY") + number(native,"surfaceHeight")
        // Scroll in the content area BELOW the native AVPlayer. A swipe from
        // the WebView center can land on the UIKit video overlay on iPad and
        // become a video tap instead of scrolling the page.
        let lower = min(max(80,height-100),max(height*0.68,surfaceBottom+80))
        let upper = max(surfaceBottom+30,min(lower-240,height*0.50))
        guard lower-upper >= 90 else {
            app.webViews.firstMatch.swipeUp()
            return
        }
        let x=max(20,min(width-20,width*0.5))
        let startY=towardUp ? lower : upper
        let endY=towardUp ? upper : lower
        let origin=app.webViews.firstMatch.coordinate(withNormalizedOffset:.zero)
        origin.withOffset(CGVector(dx:x,dy:startY)).press(
            forDuration:0.08,
            thenDragTo:origin.withOffset(CGVector(dx:x,dy:endY)))
    }

    private func regressionTap(_ key: String) throws {
        if key == "watchAudio" || key == "watchVideo" {
            try tapWebButton(key == "watchAudio" ? "Audio" : "Video")
            return
        }
        let diagnostics = app.buttons["ist-simulator-hide-controls"]
        if diagnostics.exists && diagnostics.isHittable { diagnostics.tap() }
        for _ in 0..<9 {
            let fullState=snapshot()
            let snap=fullState["regression"] as? [String:Any] ?? [:]
            let controls=snap["controls"] as? [String: [String:Any]] ?? [:]
            if let point=controls[key] {
                let previousClick=number(snap,"lastClickSequence")
                let previousAccountClick=number(snap,"accountClickSequence")
                app.webViews.firstMatch.coordinate(withNormalizedOffset:.zero)
                    .withOffset(CGVector(dx:number(point,"x"),dy:number(point,"y"))).tap()
                // Require a real captured DOM click on the requested control.
                let deadline=Date().addingTimeInterval(3)
                while Date() < deadline {
                    let observed=regression()
                    let genericClick =
                        number(observed,"lastClickSequence") > previousClick &&
                        observed["lastClickKey"] as? String == key
                    let accountClick =
                        number(observed,"accountClickSequence") > previousAccountClick &&
                        observed["accountClickKey"] as? String == key
                    if genericClick || accountClick { return }
                    RunLoop.current.run(until:Date().addingTimeInterval(0.2))
                }
                // WKWebView coordinate taps can miss an otherwise visible
                // library tab after native overlays/layout changes. Retry the
                // actual accessible button, not the same stale coordinates.
                if key == "playlists" || key == "downloads" {
                    let label = key == "playlists" ? "Playlists" : "Downloads"
                    let button=app.webViews.buttons.matching(
                        NSPredicate(format:"label CONTAINS[c] %@",label)
                    ).firstMatch
                    if button.exists && button.isHittable {
                        button.tap()
                        let fallbackDeadline=Date().addingTimeInterval(3)
                        while Date()<fallbackDeadline {
                            let observed=regression()
                            if number(observed,"lastClickSequence") > previousClick &&
                               observed["lastClickKey"] as? String == key { return }
                            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
                        }
                    }
                }
                continue
            }
            let rects=snap["rects"] as? [String:[String:Any]] ?? [:]
            if rects[key] == nil {
                regressionScroll(fullState,towardUp:true)
            } else if ["playlists","downloads"].contains(key),
                      let tabs = snap["libraryTabsRect"] as? [String:Any],
                      number(tabs,"w") > 80, number(tabs,"h") > 12 {
                let left = number(tabs,"x") + number(tabs,"w") * 0.18
                let right = number(tabs,"x") + number(tabs,"w") * 0.82
                let y = number(tabs,"y") + number(tabs,"h") / 2
                let web = app.webViews.firstMatch.coordinate(withNormalizedOffset:.zero)
                let startX = number(rects[key] ?? [:],"x") > right ? right : left
                let endX = number(rects[key] ?? [:],"x") > right ? left:right
                web.withOffset(CGVector(dx:startX,dy:y)).press(
                    forDuration:0.10,
                    thenDragTo:web.withOffset(CGVector(dx:endX,dy:y)))
            } else {
                let targetY=number(rects[key] ?? [:],"y")
                let surfaceTop=number((fullState["nativePlayer"] as? [String:Any] ?? [:]),"surfaceY")
                let surfaceBottom=surfaceTop+number((fullState["nativePlayer"] as? [String:Any] ?? [:]),"surfaceHeight")
                let directionUp: Bool
                if targetY < 0 { directionUp=false }
                else if targetY > number(snap,"height") { directionUp=true }
                else if surfaceTop > 0 && targetY >= surfaceTop && targetY <= surfaceBottom { directionUp=false }
                else { directionUp=targetY >= number(snap,"height")*0.55 }
                regressionScroll(fullState,towardUp:directionUp)
            }
        }
        XCTFail("Real DOM click did not register or native control was unavailable: \(key)")
        throw Failure.timedOut(key)
    }

    private func regressionPressHomeAndWaitForSpringBoard(_ message: String,
                                                          timeout: TimeInterval = 20) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        // SpringBoard becoming foreground proves Home actually left Irgun.
        // XCUIApplication.state can lag on iPad while background audio is active.
        _ = try waitFor(message, timeout: timeout) { _ in
            springboard.state == .runningForeground
        }
    }

    private func regressionKeyboardDone() {
        try? dismissNativeKeyboard()
    }

    private func regressionSelectAllText(_ field: XCUIElement) -> Bool {
        field.press(forDuration:1.0)
        let selectAll=app.descendants(matching:.any).matching(
            NSPredicate(format:"label CONTAINS[c] %@", "Select All")
        ).firstMatch
        guard selectAll.waitForExistence(timeout:2),selectAll.isHittable else { return false }
        selectAll.tap()
        return true
    }

    private func regressionEnter(_ key: String, _ text: String) throws {
        try regressionTap(key)
        let field=key=="loginPassword" ? app.secureTextFields.firstMatch : app.textFields.firstMatch
        guard field.waitForExistence(timeout:8) else {
            XCTFail("Native keyboard field \(key) missing")
            throw Failure.timedOut(key)
        }
        // A verified DOM click doesn't prove XCTest has keyboard focus: after
        // sign-in the profile form can display Name but leave UIKit unfocused.
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout:5) {
            field.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5)).tap()
        }
        guard app.keyboards.firstMatch.waitForExistence(timeout:10) else {
            XCTFail("Native keyboard did not open for \(key); refuse to synthesize blind typing")
            throw Failure.timedOut("keyboard for \(key)")
        }
        let old=(field.value as? String ?? "")
        if old != text {
            let needsSelectAll = ["profileName","playlistName"].contains(key) && !old.isEmpty
            if needsSelectAll {
                if regressionSelectAllText(field) {
                    field.typeText(text)
                } else {
                    // Fall back to real keyboard deletion at the end of the
                    // existing value, then verify the DOM value before typing.
                    field.tap()
                    field.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
                    field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,
                                          count:old.utf16.count+12))
                    let clearDeadline=Date().addingTimeInterval(3)
                    while Date()<clearDeadline {
                        let value=regression()[key=="profileName" ? "profileName" : "playlistName"] as? String
                        if value == "" { break }
                        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
                    }
                    let value=regression()[key=="profileName" ? "profileName" : "playlistName"] as? String
                    if value == "" {
                        field.typeText(text)
                    } else if regressionSelectAllText(field) {
                        field.typeText(text)
                    } else {
                        XCTFail("Could not reliably select or clear the existing text in \(key)")
                        throw Failure.timedOut("select all text in \(key)")
                    }
                }
            } else {
                if !old.isEmpty {
                    field.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
                    field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,
                                          count:old.utf16.count+8))
                }
                field.typeText(text)
            }
        }
        if key=="profileName" {
            try regressionWait("Real keyboard entered the requested profile name",timeout:15) {
                $0["profileName"] as? String == text
            }
        }
        if key=="playlistName" {
            try regressionWait("Real keyboard entered the requested playlist name",timeout:10) {
                $0["playlistName"] as? String == text
            }
        }
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
        try nativeEnterLoginField("email",email)
        let submittedBefore = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        try nativeEnterLoginField("password",password)
        // WebKit's native Go/Return may have submitted already. A second
        // login tap must NOT duplicate the in-flight POST or race a render.
        let submittedAfter = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        if submittedAfter <= submittedBefore && regression()["loggedIn"] as? Bool != true {
            try nativeSubmitLoginForm()
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
        XCTAssertTrue(regressionSingleVideoOwner(s),"Single native AVPlayer or web video required with no competing HTML audio")
        XCTAssertEqual(s["audioPlaying"] as? Bool,false,"HTML audio must not play simultaneously")
    }

    private func regressionOpenThroughActualLibrary() throws {
        // Exercise the SAME visible Shiurim > Watch path a user follows.
        // Do not rely on a hidden simulator diagnostic button or invoke JS.
        try regressionTap("shiurim")
        // A playable Watch button may exist below the viewport. Waiting
        // for it to be immediately visible is a deadlock: scroll it into view
        // using real WKWebView gestures before requiring the actual DOM click.
        try regressionWait("Audio-capable Watch card exists in loaded library", timeout: 60) {
            let rects = $0["rects"] as? [String:[String:Any]] ?? [:]
            return rects["open"] != nil
        }
        try regressionTap("open")
        _ = try waitFor("Real backed-up Watch control starts direct HLS or its own MP4", timeout: 120) { s in
            let source = s["videoSource"] as? String ?? ""
            let sameMP4 = s["backend"] as? String == "mp4" &&
                source.contains("/media/") && source.contains("/video.mp4")
            return s["mode"] as? String == "video" && s["ready"] as? Bool == true &&
                (s["backend"] as? String == "hls-native" || sameMP4) &&
                ["1235946832","1235511026"].contains(s["id"] as? String ?? "") &&
                s["videoPlaying"] as? Bool == true && s["videoVisible"] as? Bool == true &&
                self.regressionSingleVideoOwner(s)
        }
        try regressionVideoMoving()
        try regressionWait("Native Watch button picked audio-capable video") {
            $0["hasAudio"] as? Bool == true
        }
    }

    private func regressionActivateSample() throws {
        // Debug controls may intentionally be hidden during native form entry.
        let diagnostic = app.buttons["ist-simulator-open"]
        if diagnostic.exists && diagnostic.isHittable {
            try openSample()
            try regressionVideoMoving()
            try regressionWait("Video lecture must support its audio counterpart") {
                $0["hasAudio"] as? Bool == true
            }
        } else {
            try regressionOpenThroughActualLibrary()
        }
    }

    func testRegressionBackgroundAudioAndReopenControls() throws {
        try regressionActivateSample()
        let initial = snapshot()
        let initialNative = initial["nativePlayer"] as? [String: Any] ?? [:]
        let start = number(initial, "videoTime")
        let originalID = initialNative["id"] as? String ?? ""
        let originalEpoch = number(initialNative, "itemEpoch")
        XCTAssertFalse(originalID.isEmpty, "Background playback must start with a real native item")
        try regressionPressHomeAndWaitForSpringBoard("SpringBoard must become foreground after Home")
        let backgroundPlayback = try waitFor("The same native AVPlayer keeps playing while backgrounded",timeout:25) { state in
            let n = state["nativePlayer"] as? [String: Any] ?? [:]
            return n["active"] as? Bool == true && n["mode"] as? String == "video" &&
                   n["playing"] as? Bool == true && n["id"] as? String == originalID &&
                   self.number(state, "videoTime") >= max(0, start - 3)
        }
        let backgroundStart = number(backgroundPlayback, "videoTime")
        Thread.sleep(forTimeInterval:16)
        let progressed = snapshot()
        let progressedNative = progressed["nativePlayer"] as? [String: Any] ?? [:]
        XCTAssertEqual(progressedNative["mode"] as? String, "video")
        XCTAssertEqual(progressedNative["playing"] as? Bool, true)
        XCTAssertEqual(progressedNative["id"] as? String, originalID,
                       "Home must not replace the lecture or create a second player")
        XCTAssertEqual(number(progressedNative, "itemEpoch"), originalEpoch,
                       "Background playback must keep the same AVPlayerItem")
        XCTAssertGreaterThan(number(progressed, "videoTime"), backgroundStart + 3,
                             "The native player's audio clock must keep advancing in background")
        app.activate()
        let resumed = try waitFor("Foreground restores the HLS video at the background playback position",timeout:90) {
            $0["mode"] as? String == "video" && $0["videoPlaying"] as? Bool == true &&
            $0["videoVisible"] as? Bool == true &&
            self.number($0,"videoTime") >= max(0,self.number(progressed,"videoTime")-3)
        }
        XCTAssertTrue(regressionSingleVideoOwner(resumed))
        videoPoint(0.5,0.25).tap()
        _ = try waitFor("Tap reveals native controls after foreground",timeout:12) {
            $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true
        }
        try tapWebButton("Pause video")
        _ = try waitFor("Pause after background return works") { $0["videoPlaying"] as? Bool == false }
        try tapWebButton("Play video")
        try regressionVideoMoving()
    }

    private func regressionArmPush(target: String, previousActions: Int) throws {
        XCTAssertFalse(target.isEmpty,"Notification must target the currently playing real shiur")
        let payload = try JSONSerialization.data(withJSONObject:
            ["id":target,"previousActions":previousActions]) + Data([10])
        let connection = NWConnection(host:"127.0.0.1",port:47312,using:.tcp)
        let done = DispatchSemaphore(value:0)
        let lock = NSLock()
        var acknowledged = false
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content:payload,completion:.contentProcessed { _ in
                    connection.receive(minimumIncompleteLength:1,maximumLength:32) { data,_,_,_ in
                        lock.lock()
                        acknowledged = String(data:data ?? Data(),encoding:.utf8)?.hasPrefix("READY") == true
                        lock.unlock()
                        done.signal()
                    }
                })
            } else if case .failed = state { done.signal() }
        }
        connection.start(queue:DispatchQueue(label:"org.irgun.regression.push-ready"))
        let received = done.wait(timeout:.now()+15) == .success
        connection.cancel()
        lock.lock(); let ready = acknowledged; lock.unlock()
        guard received && ready else {
            XCTFail("Real host APNs sender did not acknowledge the backgrounded notification test")
            throw Failure.timedOut("Push sender readiness")
        }
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
        let target = snapshot()["id"] as? String ?? ""
        let position = number(snapshot(),"videoTime")
        try regressionPressHomeAndWaitForSpringBoard("SpringBoard must become foreground before APNs delivery")
        // XCTest's XCUIApplication.state can remain stale as .runningForeground
        // while iOS continues our AVPlayer's background audio. SpringBoard's
        // actual foreground state is the reliable OS-visible Home verification;
        // the test still requires simctl delivery AND a native notification tap.
        XCTAssertEqual(springboard.state, .runningForeground,
                       "Push delivery requires SpringBoard to own the foreground")
        try regressionArmPush(target: target, previousActions: initial)
        let notification=springboard.descendants(matching:.any)
            .matching(NSPredicate(format:"label CONTAINS %@", "Irgun QA Playback")).firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout:120),
                      "Simulator notification must really appear in SpringBoard")
        XCTAssertTrue(notification.isHittable,"Simulated push must be tappable")
        notification.tap()
        try regressionWait("Notification action must reach the app's native listener",timeout:45) {
            ($0["pushActions"] as? Int ?? 0)>initial &&
            $0["pushWatchTarget"] as? Bool == true
        }
        let reopened = try waitFor("Notification reopening restores the same inline playing video",timeout:75) {
            $0["mode"] as? String == "video" && $0["pip"] as? Bool == false &&
            $0["videoVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true &&
            self.regressionSingleVideoOwner($0) &&
            $0["id"] as? String == target && self.number($0,"videoTime") >= max(0,position-3)
        }
        // The native player intentionally starts with controls hidden and then
        // auto-hides them, matching Android. If hidden after notification tap,
        // reveal them with a real picture tap before exercising Pause/Play.
        if reopened["controlsVisible"] as? Bool != true {
            videoPoint(0.5,0.25).tap()
            _ = try waitFor("Picture tap reveals controls after notification launch",timeout:12) {
                $0["controlsVisible"] as? Bool == true && $0["videoPlaying"] as? Bool == true
            }
        }
        for _ in 0..<2 {
            if snapshot()["videoPlaying"] as? Bool == false { break }
            try tapWebButton("Pause video")
            let deadline=Date().addingTimeInterval(4)
            while Date() < deadline &&
                  snapshot()["videoPlaying"] as? Bool != false {
                RunLoop.current.run(until:Date().addingTimeInterval(0.2))
            }
        }
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
        _ = try waitFor("Expand restores the inline video surface") {
            $0["minimized"] as? Bool == false && $0["videoVisible"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true
        }
        videoPoint(0.5,0.25).tap()
        _ = try waitFor("Tap reveals controls after expanding mini") {
            $0["minimized"] as? Bool == false && $0["controlsVisible"] as? Bool == true
        }
        XCTAssertTrue(regressionSingleVideoOwner(snapshot()))
        let capability = snapshot()
        let native = capability["nativePlayer"] as? [String:Any] ?? [:]
        guard native["pipSupported"] as? Bool == true else {
            throw XCTSkip("Native system PiP is unsupported in this simulator; physical-device PiP verification remains required")
        }
        _ = try waitFor("Native system PiP becomes available",timeout:15) { state in
            let n = state["nativePlayer"] as? [String:Any] ?? [:]
            return n["pipPossible"] as? Bool == true
        }
        try tapWebButton("Picture in Picture")
        _ = try waitFor("PiP genuinely enters",timeout:40) { $0["pip"] as? Bool == true }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval:5)
        app.activate()
        let returned = try waitFor("PiP return restores inline playback",timeout:60) {
            $0["pip"] as? Bool == false && $0["minimized"] as? Bool == false &&
            $0["videoVisible"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true &&
            self.number($0,"videoTime")>prior &&
            self.regressionSingleVideoOwner($0)
        }
        if returned["controlsVisible"] as? Bool != true {
            videoPoint(0.5,0.25).tap()
            _ = try waitFor("Tap reveals native controls after PiP return",timeout:12) {
                $0["pip"] as? Bool == false &&
                $0["controlsVisible"] as? Bool == true &&
                $0["videoPlaying"] as? Bool == true
            }
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
            self.regressionSingleVideoOwner($0)
        }
        try regressionVideoMoving()
    }

    // iOS 26 WebKit can present <select> either as a traditional picker wheel
    // or as a native popover list. Both paths tap the actual native option.
    // We then assert the real HTMLVideoElement playbackRate, never a stub.
    private func chooseRealVideoSpeed(_ label: String) throws {
        // Select real native AVPlayer speed with UIKit, not a stale HTML player.
        let n=snapshot()["nativePlayer"] as? [String:Any] ?? [:]
        if n["active"] as? Bool == true && n["mode"] as? String == "video" {
            if n["controlsVisible"] as? Bool != true {
                videoPoint(0.5,0.25).tap()
                _ = try waitFor("Reveal native speed controls") {
                    ($0["nativePlayer"] as? [String:Any])?["controlsVisible"] as? Bool == true
                }
            }
            try tapWebButton("Playback speed")
            let title=label == "1.5x" ? "1.5×" : "1×"
            let choice=app.buttons[title].firstMatch
            guard choice.waitForExistence(timeout:12) && choice.isHittable else {
                XCTFail("Native speed choice unavailable: " + title)
                throw Failure.timedOut("native speed choice")
            }
            choice.tap()
            return
        }
        // Retain actual HTML-video fallback controls.
        let controls = regression()["controls"] as? [String:[String:Any]] ?? [:]
        if controls["videoSpeedToggle"] != nil {
            try regressionTap("videoSpeedToggle")
            let key = label == "1.5x" ? "videoSpeed15" : "videoSpeed10"
            try regressionWait("Real speed choice is visible and hit-tested", timeout: 50) {
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
        // Real user navigation after a cold process relaunch, not the
        // test-only debug overlay; verify live decoder and 1.5x rate.
        try regressionOpenThroughActualLibrary()
        XCTAssertEqual(number(snapshot(),"speed"),1.5,accuracy:0.02,
                       "User-selected speed should survive app relaunch")
        XCTAssertEqual(number(regression(),"videoSpeedChoice"),1.5,accuracy:0.02)
        try regressionVideoMoving()
        try regressionTap("watchAudio")
        _ = try waitFor("Audio inherits chosen 1.5x speed and keeps playing",timeout:60) {
            $0["mode"] as? String == "audio" && self.regressionAudioIsPlaying($0) &&
            abs(self.number($0,"speed")-1.5)<0.02
        }
        try regressionTap("watchVideo")
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
            XCTAssertTrue(regressionSingleVideoOwner(s))
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
        _ = try waitFor("Player resumes after real lock/unlock",timeout:70) {
            $0["videoPlaying"] as? Bool == true && $0["videoVisible"] as? Bool == true
        }
        // Controls are supposed to auto-hide. Reveal them with a real surface tap.
        videoPoint(0.5,0.25).tap()
        _ = try waitFor("Tap reveals controls after lock/unlock",timeout:12) {
            $0["videoPlaying"] as? Bool == true && $0["controlsVisible"] as? Bool == true
        }
        try regressionVideoMoving()
        for _ in 0..<3 {
            let previous=number(snapshot(),"videoTime")
            try regressionTap("watchAudio")
            let audio=try waitFor("Long-session mode switch gives active audio",timeout:70) {
                $0["mode"] as? String == "audio" && self.regressionAudioIsPlaying($0) &&
                self.regressionAudioPosition($0)>=max(0,previous-3)
            }
            let audioTime=regressionAudioPosition(audio)
            try regressionTap("watchVideo")
            _ = try waitFor("Long-session return yields video only",timeout:90) {
                $0["mode"] as? String == "video" && $0["videoPlaying"] as? Bool == true &&
                $0["audioPlaying"] as? Bool == false && self.regressionSingleVideoOwner($0) &&
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
        // After real email/password entry the debug overlay may be hidden.
        // Navigate to the video using actual Shiurim and Watch controls.
        try regressionOpenThroughActualLibrary()
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
                self.regressionAudioIsPlaying($0) &&
                reg["online"] as? Bool == false &&
                self.regressionAudioPosition($0)>1
        }
        let at=regressionAudioPosition(playing)
        _ = try waitFor("Offline audio clock keeps advancing without server access",timeout:45) {
            let reg=$0["regression"] as? [String:Any] ?? [:]
            return reg["offlineCurrent"] as? Bool == true &&
                self.regressionAudioIsPlaying($0) &&
                self.regressionAudioPosition($0)>at+3
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
        try regressionTap("account")
        // Session restoration can finish just after the initial snapshot. Wait
        // until it settles before deciding whether this test starts logged out.
        try regressionWait("Account session restoration settles",timeout:90) {
            $0["loginForm"] as? Bool == true ||
            ($0["loggedIn"] as? Bool == true && $0["authenticatedProfile"] as? Bool == true)
        }
        if regression()["loggedIn"] as? Bool == true {
            try regressionTap("logout")
            try regressionWait("Logout reaches signed-out form",timeout:60) {
                $0["loggedIn"] as? Bool == false && $0["loginForm"] as? Bool == true
            }
        }
        try regressionWait("Sign-in form is native visible") {
            $0["loginForm"] as? Bool == true && $0["loggedIn"] as? Bool == false
        }
        try nativeEnterLoginField("email",email)
        let invalidSubmitBefore = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        try nativeEnterLoginField("password",pass+"not-valid")
        if number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount") <= invalidSubmitBefore {
            try nativeSubmitLoginForm()
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
        try nativeEnterLoginField("password",pass)
        if number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount") <= retrySubmitBefore &&
           regression()["loggedIn"] as? Bool != true {
            try nativeSubmitLoginForm()
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
            try regressionEnter("playlistName",name)
        }
        // Dismissing the keyboard does not submit this form on every iOS keyboard.
        // Tap the real Create button unless Return already saved the playlist.
        if !(regression()["syncPlaylistNames"] as? [String] ?? []).contains(name) {
            try regressionTap("createPlaylist")
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


