    // Staged from PR #25 for the combined regression suite; do not run until PR #45 merges.
    // Credentials come from private GitHub secrets through the ephemeral test scheme.
    func testRegressionAuthenticatedCommentsMediaProfile() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp() -> String { formatter.string(from: Date()) }
        let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("irgun-regression-comments-result.json")
        var checks = [String]()
        var report: [String: Any] = ["credentialsRecorded": false, "startedAt": timestamp(), "status": "running"]
        func persistReport() {
            report["checks"] = checks
            try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }
        func checked(_ label: String) { checks.append(label); persistReport() }
        persistReport()
        defer {
            report["finishedAt"] = timestamp()
            report["collectionRequests"] = (snapshot()["account"] as? [String: Any])?["requests"] ?? []
            if report["status"] as? String != "passed" { report["status"] = "failed" }
            // A native process restart clears typed form contents before evidence.
            app.terminate(); app.launch()
            report["evidenceCredentialsCleared"] = true
            persistReport()
        }
        let env = ProcessInfo.processInfo.environment
        guard let email = env["IRGUN_TEST_EMAIL"], let password = env["IRGUN_TEST_PASSWORD"], !email.isEmpty, !password.isEmpty else {
            XCTFail("Missing dedicated verified-account credentials"); return
        }
        func account() -> [String: Any] { snapshot()["account"] as? [String: Any] ?? [:] }
        func values(_ s: [String: Any], _ key: String) -> [String] { s[key] as? [String] ?? [] }
        func completedFollowRequests(_ s: [String: Any]) -> Int {
            let requests = s["requests"] as? [[String: Any]] ?? []
            return requests.filter { $0["path"] as? String == "/follows/toggle" &&
                ($0["ok"] as? Bool == true || (number($0, "finishedAt") > 0 && number($0, "status") > 0)) }.count
        }
        func successCount(_ s: [String: Any], _ path: String, _ method: String) -> Int {
            let requests = s["requests"] as? [[String: Any]] ?? []
            return requests.filter {
                $0["path"] as? String == path && $0["method"] as? String == method &&
                $0["ok"] as? Bool == true
            }.count
        }
        func successfulHistoryWrites(_ s: [String: Any]) -> Int {
            let requests = s["requests"] as? [[String: Any]] ?? []
            return requests.filter { $0["path"] as? String == "/history" && $0["ok"] as? Bool == true }.count
        }
        func awaitSuccessfulFollowRequest(after previous: Int) throws {
            try awaitAccount("Follow request returned successfully") { s in
                let requests = s["requests"] as? [[String: Any]] ?? []
                let followRequests = requests.filter { $0["path"] as? String == "/follows/toggle" }
                // A handled HTTP error must fail the test; a click alone is not enough.
                return followRequests.count > previous &&
                    followRequests.last?["ok"] as? Bool == true
            }
        }
        func awaitAccount(_ message: String, _ condition: @escaping ([String: Any]) -> Bool) throws {
            try waitFor(message, timeout: 60) { condition($0["account"] as? [String: Any] ?? [:]) }
        }
        func touch(_ key: String) throws {
            report["stage"] = "Native touch: " + key; persistReport()
            if key == "modeAudio" || key == "modeVideo" {
                // The public simulator suite already verifies these native
                // accessibility buttons. Their native coordinates account for
                // WebKit's viewport shift after email/password keyboard input.
                try tapWebButton(key == "modeAudio" ? "Audio" : "Video")
                return
            }
            let hide = app.buttons["ist-simulator-hide-controls"]
            if hide.exists && hide.isHittable { hide.tap() }
            try awaitAccount("Account control rendered: " + key) {
                let rects = $0["controlRects"] as? [String: [String: Any]] ?? [:]
                return rects[key] != nil
            }
            for _ in 0..<10 {
                let fullState = snapshot()
                let s = fullState["account"] as? [String: Any] ?? [:]
                let native = fullState["nativePlayer"] as? [String: Any] ?? [:]
                let controls = s["controls"] as? [String: [String: Any]] ?? [:]
                report["collectionRequests"] = s["requests"] ?? []
                report["lastScreen"] = s["screen"] as? String ?? ""
                report["lastControlKeys"] = controls.keys.sorted()
                report["keyboardVisible"] = app.keyboards.firstMatch.exists
                report["authBusy"] = s["authBusy"] as? Bool ?? false
                persistReport()
                if let point=controls[key] {
                    let beforeClick = number(s,"lastClickSequence")
                    let web=app.webViews.firstMatch, box=web.frame
                    XCTAssertTrue(box.width>0 && box.height>0)
                    // Use the same CSS-point mapping as the native playback suite.
                    web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:number(point,"x"),dy:number(point,"y"))).tap()
                    // JavaScript confirm blocks the observer's snapshot until
                    // XCTest responds. Do not retry the destructive tap while
                    // its real confirmation is waiting on screen.
                    if key == "commentDelete" { return }
                    // A render can move a control between observation and touch.
                    // Continue only after the real native tap produced its click.
                    let clickDeadline = Date().addingTimeInterval(3)
                    while Date() < clickDeadline {
                        let observed = account()
                        if number(observed,"lastClickSequence") > beforeClick,
                           observed["lastClickKey"] as? String == key { return }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                    continue
                }
                let rects = s["controlRects"] as? [String: [String: Any]] ?? [:]
                let scrolls = s["controlScrollers"] as? [String: [String: Any]] ?? [:]
                if let rect = rects[key], let scroll = scrolls[key],
                   number(rect,"x") < number(scroll,"left") || number(rect,"x") > number(scroll,"right") {
                    // Swipe the actual horizontally scrolling tab row. Vertical
                    // page scrolling cannot expose an offscreen Playlists tab.
                    let left=number(scroll,"left")+15, right=number(scroll,"right")-15
                    let y=(number(scroll,"top")+number(scroll,"bottom"))/2
                    let web=app.webViews.firstMatch
                    let origin=web.coordinate(withNormalizedOffset:.zero)
                    let startX=number(rect,"x")>right ? right:left
                    let endX=number(rect,"x")>right ? left:right
                    origin.withOffset(CGVector(dx:startX,dy:y)).press(forDuration:0.05,
                        thenDragTo:origin.withOffset(CGVector(dx:endX,dy:y)))
                } else if let rect = rects[key] {
                    let targetY = number(rect, "y")
                    let viewportHeight = number(s, "height")
                    let surfaceTop = number(native, "surfaceY")
                    let surfaceBottom = surfaceTop + number(native, "surfaceHeight")
                    if targetY < 0 {
                        app.webViews.firstMatch.swipeDown()
                    } else if viewportHeight > 0 && targetY > viewportHeight {
                        app.webViews.firstMatch.swipeUp()
                    } else if native["active"] as? Bool == true &&
                              native["mode"] as? String == "video" &&
                              surfaceTop > 0 && targetY >= surfaceTop && targetY <= surfaceBottom {
                        // The native AVPlayer is a UIKit overlay above WebView.
                        // If a comment control is behind that surface, scroll it
                        // below the player before tapping; otherwise repeated
                        // taps/swipes can never reach the actual DOM button.
                        app.webViews.firstMatch.swipeDown()
                    } else {
                        app.webViews.firstMatch.swipeUp()
                    }
                } else {
                    app.webViews.firstMatch.swipeUp()
                }
            }
            XCTFail("Visible account control missing: \(key)"); throw Failure.timedOut(key)
        }
        func dismissNativeKeyboard() throws {
            guard app.keyboards.firstMatch.exists else { return }
            let done=app.buttons["Done"].firstMatch
            if done.exists && done.isHittable { done.tap(); return }
            for label in ["Return", "Go", "Done", "Log In"] {
                let key=app.keyboards.buttons[label].firstMatch
                if key.exists && key.isHittable { key.tap(); return }
            }
            XCTFail("No native keyboard dismissal control"); throw Failure.timedOut("keyboard dismissal")
        }
        report["nativeLoginStartedAt"] = timestamp(); persistReport()
        try touch("account")
        try awaitAccount("Account login form rendered") { $0["authFormPresent"] as? Bool == true }
        try nativeEnterLoginField("email",email)
        try nativeEnterLoginField("password",password)
        // Return/Go can submit immediately. Give an in-flight request time to
        // settle before deciding whether the form still needs a native tap.
        let settledAfter = Date().timeIntervalSince1970 * 1000
        try awaitAccount("Native login form settled") {
            self.number($0, "observedAt") > settledAfter && $0["authBusy"] as? Bool == false
        }
        func repairNativeCredential(_ key: String, _ expected: String) throws {
            try nativeEnterLoginField(key,expected)
        }
        // The document can observe a click on Login even when HTML constraint
        // validation suppressed the submit event. Validate field shapes before
        // clicking, and repair any dropped native keystrokes once.
        func nativeEmailMatchesApproved() -> Bool {
            let entered = (app.textFields.firstMatch.value as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return entered == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func nativePasswordLengthMatches() -> Bool {
            Int(number(account(), "authPasswordLength")) == password.utf16.count
        }
        for _ in 0..<3 {
            let observed = account()
            if observed["loggedIn"] as? Bool == true { break }
            if observed["authFormPresent"] as? Bool != true { break }
            let emailCorrect = nativeEmailMatchesApproved()
            let passwordCorrectLength = nativePasswordLengthMatches()
            if observed["authFormValid"] as? Bool == true && emailCorrect && passwordCorrectLength { break }
            if observed["authEmailValid"] as? Bool != true || !emailCorrect {
                try repairNativeCredential("email", email)
            }
            if account()["authPasswordValid"] as? Bool != true || !passwordCorrectLength {
                try repairNativeCredential("password", password)
            }
            let afterRepair = Date().timeIntervalSince1970 * 1000
            try awaitAccount("Repaired login form settled") {
                self.number($0, "observedAt") > afterRepair && $0["authBusy"] as? Bool == false
            }
        }
        if account()["loggedIn"] as? Bool != true {
            let observed = account()
            XCTAssertTrue(observed["authFormValid"] as? Bool == true && nativeEmailMatchesApproved() && nativePasswordLengthMatches(),
                          "Native login fields are incomplete or not the approved credentials; see credential-free validity observations")
            let submitBefore = number(observed, "authSubmitCount")
            try nativeSubmitLoginForm()
            // The click observer runs in capture phase even when HTML constraint
            // validation suppresses submit. Require the real submit event, never
            // mistake a native tap for a successful login.
            try awaitAccount("Login form really submitted", { s in
                s["loggedIn"] as? Bool == true || self.number(s, "authSubmitCount") > submitBefore
            })
        }
        try awaitAccount("Native login and profile") {
            $0["loggedIn"] as? Bool == true && $0["profileVisible"] as? Bool == true
        }
        XCTAssertEqual(account()["isAdmin"] as? Bool, false, "Use a dedicated non-admin account")
        let authenticatedEmail = (account()["accountEmail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        XCTAssertTrue(authenticatedEmail == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "Refuse to mutate an account other than the dedicated approved account")
        checked("Native email/password login, dedicated identity and profile")
        let originalName = account()["name"] as? String ?? ""
        XCTAssertFalse(originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(account()["profileNameValue"] as? String, originalName)
        XCTAssertEqual(account()["profileNameDisplayed"] as? String, originalName)
        checked("Original account name is correct in the profile")
        func closeSavePicker() throws {
            if account()["playlistPickerOpen"] as? Bool == true { try touch("closePicker") }
            try awaitAccount("Save dialog closed") { $0["playlistPickerOpen"] as? Bool == false }
        }
        try touch("settings")
        try awaitAccount("Settings displayed") { $0["settingsVisible"] as? Bool == true }
        checked("Account settings displayed")
        try touch("shiurim")
        let historyWritesBeforeLecture = successfulHistoryWrites(account())
        try touch("open")
        try awaitAccount("Lecture opened") { !($0["watchId"] as? String ?? "").isEmpty }
        let id=account()["watchId"] as! String, before=account()
        report["accountMutationsStartedAt"] = timestamp(); persistReport()
        try touch("like")
        try awaitAccount("Like toggled") { values($0,"likes").contains(id) != values(before,"likes").contains(id) }
        checked("Native Like toggle")
        try touch("save"); try touch("later")
        try awaitAccount("Watch Later toggled") { values($0,"later").contains(id) != values(before,"later").contains(id) }
        try closeSavePicker(); checked("Native Watch Later toggle and dialog closure")
        let followRequestCount = completedFollowRequests(account())
        try touch("follow")
        try awaitSuccessfulFollowRequest(after: followRequestCount)
        try awaitAccount("Follow toggled") { values($0,"follows").sorted() != values(before,"follows").sorted() }
        checked("Native speaker follow toggle")
        try awaitAccount("Playing lecture records real history") {
            $0["videoPlaying"] as? Bool == true &&
            self.number($0,"videoTime") > 1 &&
            values($0,"history").contains(id) &&
            successfulHistoryWrites($0) > historyWritesBeforeLecture
        }
        checked("Actual playing lecture history recorded")
        XCTAssertEqual(account()["watchHasAudio"] as? Bool, true, "Test lecture must have real audio")
        let originalVideoTime = number(snapshot(), "videoTime")
        try touch("modeAudio")
        let audioState = try waitFor("Video to Audio transfers real playback", timeout: 90) {
            $0["mode"] as? String == "audio" && self.regressionAudioIsPlaying($0) &&
            $0["videoPlaying"] as? Bool == false && $0["pendingSeek"] as? Bool == false &&
            self.regressionAudioPosition($0) >= max(0, originalVideoTime - 3)
        }
        let audioStart = regressionAudioPosition(audioState)
        let audioMoving = try waitFor("Audio advances after Video to Audio") {
            $0["mode"] as? String == "audio" && self.regressionAudioIsPlaying($0) &&
            self.regressionAudioPosition($0) >= audioStart + 1
        }
        checked("Video to Audio retains playback and position")
        let audioEnd = regressionAudioPosition(audioMoving)
        try touch("modeVideo")
        _ = try waitFor("Audio to Video restores one playing video owner", timeout: 90) {
            $0["mode"] as? String == "video" && $0["ready"] as? Bool == true &&
            $0["videoPlaying"] as? Bool == true && $0["videoVisible"] as? Bool == true &&
            $0["audioPlaying"] as? Bool == false && self.regressionSingleVideoOwner($0) &&
            self.number($0, "videoTime") >= max(0, audioEnd - 3)
        }
        let videoFramesBefore = number(snapshot(), "frameTime")
        _ = try waitFor("Actual video frames advance after Audio to Video", timeout: 60) {
            $0["videoPlaying"] as? Bool == true && $0["videoVisible"] as? Bool == true &&
            self.number($0, "frameTime") > videoFramesBefore + 0.5
        }
        checked("Audio to Video retains position and advances visible frames")
        XCTAssertEqual(account()["name"] as? String, originalName)

        let commentMarker = String(Int(Date().timeIntervalSince1970 * 1000))
        try awaitAccount("Comment form loaded before posting") {
            $0["commentsLoading"] as? Bool == false && $0["commentsError"] as? Bool == false
        }
        try touch("commentText")
        let nativeComposer = app.webViews.textViews.firstMatch
        XCTAssertTrue(nativeComposer.waitForExistence(timeout: 10), "Comment composer must exist")
        nativeComposer.typeText("IST iOS QA \(commentMarker) created")
        // Prove native typing reached the actual comment form before allowing
        // a server mutation; typing into some other WKWebView textarea would
        // otherwise post an unrelated user's draft by accident.
        try awaitAccount("Native keyboard entered the exact disposable QA comment") {
            $0["qaDraftValid"] as? Bool == true
        }
        let postBefore = successCount(account(), "/comments", "POST")
        try touch("commentPost")
        try awaitAccount("QA comment POST accepted by the actual server") {
            successCount($0, "/comments", "POST") > postBefore &&
            $0["commentDraftEmpty"] as? Bool == true
        }
        try awaitAccount("The server returned the posted QA comment and correctly identified its owner") {
            $0["qaCommentReturned"] as? Bool == true &&
            $0["qaCommentReturnedOwned"] as? Bool == true &&
            $0["qaCommentPhase"] as? String == "created"
        }
        // Posting can leave the native keyboard open even after the composer
        // clears. Dismiss it before scrolling to the comment's edit control.
        try dismissNativeKeyboard()
        _ = try waitFor("Comment composer keyboard closes before editing",timeout:10) { _ in
            !self.app.keyboards.firstMatch.exists
        }
        checked("Comment POST persisted, visible to its owner and submitted draft cleared")
        try touch("commentEdit")
        try awaitAccount("Owned comment edit UI opened") {
            let rects = $0["controlRects"] as? [String: [String: Any]] ?? [:]
            return rects["commentEditText"] != nil
        }
        let nativeEditor = app.webViews.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", commentMarker)
        ).firstMatch
        XCTAssertTrue(nativeEditor.waitForExistence(timeout: 10), "QA comment editor must exist")
        nativeEditor.typeText(" updated")
        try dismissNativeKeyboard()
        _ = try waitFor("Native comment-edit keyboard closes before Save") { _ in
            !self.app.keyboards.firstMatch.exists
        }
        let editBefore = successCount(account(), "/comments/edit", "PUT")
        try touch("commentSave")
        try awaitAccount("Comment edit persisted on server") {
            $0["qaCommentPhase"] as? String == "edited" &&
            successCount($0, "/comments/edit", "PUT") > editBefore
        }
        checked("Comment edit saved and verified")
        let deleteBefore = successCount(account(), "/comments/delete", "POST")
        try touch("commentDelete")
        let deleteAlert = app.alerts.firstMatch
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 8), "Comment deletion confirmation must appear")
        XCTAssertTrue(deleteAlert.staticTexts.matching(
            NSPredicate(format:"label CONTAINS[c] %@","delete this comment")
        ).firstMatch.exists,"Only the requested QA comment deletion may be confirmed")
        let confirm = deleteAlert.buttons.matching(
            NSPredicate(format:"label IN %@",["OK","Ok","Delete"])
        ).firstMatch
        guard confirm.exists && confirm.isHittable else {
            XCTFail("Native comment confirmation button missing")
            throw Failure.timedOut("Delete confirmation")
        }
        confirm.tap()
        try awaitAccount("Comment delete succeeded on server") {
            $0["qaCommentPhase"] as? String == "absent" &&
            successCount($0, "/comments/delete", "POST") > deleteBefore
        }
        checked("Comment deleted successfully")
        XCTAssertEqual(account()["name"] as? String, originalName)
        // Leave playback through a real process restart so a top-edge player
        // control cannot be obscured by simulator chrome. This also proves the
        // authenticated session survives before creating server-side data.
        app.terminate(); app.launch()
        try awaitAccount("Signed-in library reloads after playback") {
            $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true &&
            $0["name"] as? String == originalName
        }
        try touch("account")
        try awaitAccount("Profile name survives real process restart") {
            $0["profileNameValue"] as? String == originalName &&
            $0["profileNameDisplayed"] as? String == originalName
        }
        checked("Account name persists after restart")
        let commentReadsBefore = successCount(account(), "/comments", "GET")
        try touch("shiurim"); try touch("open")
        try awaitAccount("Deleted QA comment stays absent after restart and fresh server read") {
            $0["watchId"] as? String == id &&
            $0["qaCommentMarker"] as? String == commentMarker &&
            $0["commentsLoading"] as? Bool == false &&
            $0["commentsError"] as? Bool == false &&
            successCount($0, "/comments", "GET") > commentReadsBefore &&
            $0["qaCommentReturned"] as? Bool == false &&
            $0["qaCommentPhase"] as? String == "absent"
        }
        checked("Comment stays deleted after native restart and fresh server GET")
        app.terminate(); app.launch()
        try awaitAccount("Account restores after independent deleted-comment verification") {
            $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true &&
            $0["name"] as? String == originalName
        }
        try touch("library")
        try awaitAccount("Library screen rendered") {
            guard $0["screen"] as? String == "library" else { return false }
            let rects = $0["controlRects"] as? [String: [String: Any]] ?? [:]
            return rects["playlists"] != nil
        }
        try touch("playlists")
        let playlistName="Irgun-QA-\(Int(Date().timeIntervalSince1970))"
        try touch("playlistName"); app.textFields.firstMatch.typeText(playlistName + "\n")
        func hasPlaylist(_ s:[String:Any]) -> Bool { (s["playlists"] as? [[String:Any]] ?? []).contains { $0["name"] as? String == playlistName } }
        try awaitAccount("Playlist created") { hasPlaylist($0) }
        checked("QA playlist created")
        let changed=account()
        app.terminate(); app.launch()
        try awaitAccount("Session and playlist survive process restart") { $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true && hasPlaylist($0) }
        XCTAssertEqual(values(account(),"likes").contains(id),values(changed,"likes").contains(id))
        XCTAssertEqual(values(account(),"later").contains(id),values(changed,"later").contains(id))
        XCTAssertEqual(values(account(),"follows").sorted(),values(changed,"follows").sorted())
        XCTAssertTrue(values(account(),"history").contains(id),"Playback history must survive relaunch")
        XCTAssertEqual(account()["name"] as? String, originalName, "Name changed unexpectedly after another restart")
        checked("Session and server-loaded collections persist after native process restart")
        evidence("logged-in-account-restored")
        // Restore the lecture flags. Keep the uniquely named QA playlist for inspection.
        try touch("shiurim"); try touch("open")
        try awaitAccount("Same lecture for cleanup") { $0["watchId"] as? String == id }
        // Restore one flag at a time and verify each actual state transition.
        // This isolates the failing operation instead of issuing all requests
        // before a combined assertion.
        try touch("like")
        try awaitAccount("Like restored") {
            values($0,"likes").contains(id) == values(before,"likes").contains(id)
        }
        checked("Native Like flag restored")
        try touch("save"); try touch("later"); try closeSavePicker()
        try awaitAccount("Watch Later restored") {
            values($0,"later").contains(id) == values(before,"later").contains(id)
        }
        checked("Native Watch Later flag restored")
        let followRestoreRequestCount = completedFollowRequests(account())
        try touch("follow")
        try awaitSuccessfulFollowRequest(after: followRestoreRequestCount)
        try awaitAccount("Follow restored") {
            values($0,"follows").sorted() == values(before,"follows").sorted()
        }
        checked("Native Follow flag restored")
        try awaitAccount("Lecture flags restored") { values($0,"likes").contains(id) == values(before,"likes").contains(id) && values($0,"later").contains(id) == values(before,"later").contains(id) && values($0,"follows").sorted() == values(before,"follows").sorted() }
        checked("Lecture flags restored")
        // Relaunch rather than depending on the same top-edge close control,
        // then require the restored server state and session to load normally.
        app.terminate(); app.launch()
        try awaitAccount("Restored account reloads before logout") {
            $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true &&
            values($0,"likes").contains(id) == values(before,"likes").contains(id) &&
            values($0,"later").contains(id) == values(before,"later").contains(id) &&
            values($0,"follows").sorted() == values(before,"follows").sorted()
        }
        try touch("account"); try touch("logout")
        try awaitAccount("Logout clears account state") { $0["loggedIn"] as? Bool == false && values($0,"likes").isEmpty && values($0,"later").isEmpty && ($0["playlists"] as? [[String:Any]] ?? []).isEmpty }
        checked("Logout clears account state")
        report["accountMutationsFinishedAt"] = timestamp(); report["status"] = "passed"; persistReport()
    }


