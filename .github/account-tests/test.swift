    // Credentials come from private GitHub secrets through the ephemeral test scheme.
    func testLoggedInAccountPersistenceAndLogout() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp() -> String { formatter.string(from: Date()) }
        let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("irgun-account-result.json")
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
            let hide = app.buttons["ist-simulator-hide-controls"]
            if hide.exists && hide.isHittable { hide.tap() }
            try awaitAccount("Account control rendered: " + key) {
                let rects = $0["controlRects"] as? [String: [String: Any]] ?? [:]
                return rects[key] != nil
            }
            for _ in 0..<7 {
                let s=account(), controls=s["controls"] as? [String: [String: Any]] ?? [:]
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
                } else if let rect = rects[key], number(rect,"y") < 0 {
                    app.webViews.firstMatch.swipeDown()
                } else { app.webViews.firstMatch.swipeUp() }
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
        try touch("email"); app.textFields.firstMatch.typeText(email); try dismissNativeKeyboard()
        try touch("password"); app.secureTextFields.firstMatch.typeText(password); try dismissNativeKeyboard()
        // A native Return/Go key may submit. Wait for that request instead of
        // searching for the disabled or already-removed Login button.
        let settledAfter = Date().timeIntervalSince1970 * 1000
        try awaitAccount("Native login form settled") { self.number($0,"observedAt") > settledAfter && $0["authBusy"] as? Bool == false }
        if account()["loggedIn"] as? Bool != true { try touch("login") }
        try awaitAccount("Native login and profile") { $0["loggedIn"] as? Bool == true && $0["profileVisible"] as? Bool == true }
        XCTAssertEqual(account()["isAdmin"] as? Bool, false, "Use a dedicated non-admin account")
        let authenticatedEmail = (account()["accountEmail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        XCTAssertTrue(authenticatedEmail == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "Refuse to mutate an account other than the dedicated approved account")
        checked("Native email/password login, dedicated identity and profile")
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
        // Leave playback through a real process restart so a top-edge player
        // control cannot be obscured by simulator chrome. This also proves the
        // authenticated session survives before creating server-side data.
        app.terminate(); app.launch()
        try awaitAccount("Signed-in library reloads after playback") {
            $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true
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
