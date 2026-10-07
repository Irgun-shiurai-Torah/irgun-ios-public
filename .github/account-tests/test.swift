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
        func awaitAccount(_ message: String, _ condition: @escaping ([String: Any]) -> Bool) throws {
            try waitFor(message, timeout: 60) { condition($0["account"] as? [String: Any] ?? [:]) }
        }
        func touch(_ key: String) throws {
            for _ in 0..<7 {
                let s=account(), controls=s["controls"] as? [String: [String: Any]] ?? [:]
                if let point=controls[key] {
                    let web=app.webViews.firstMatch, box=web.frame
                    let x=number(point,"x") / number(s,"width"), y=number(point,"y") / number(s,"height")
                    XCTAssertTrue(box.width>0 && box.height>0)
                    web.coordinate(withNormalizedOffset:CGVector(dx:x,dy:y)).tap()
                    return
                }
                app.webViews.firstMatch.swipeUp()
            }
            XCTFail("Visible account control missing: \(key)"); throw Failure.timedOut(key)
        }
        report["nativeLoginStartedAt"] = timestamp(); persistReport()
        try touch("account")
        try touch("email"); app.textFields.firstMatch.typeText(email)
        try touch("password"); app.secureTextFields.firstMatch.typeText(password + "\n")
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
        try touch("shiurim"); try touch("open")
        try awaitAccount("Lecture opened") { !($0["watchId"] as? String ?? "").isEmpty }
        let id=account()["watchId"] as! String, before=account()
        report["accountMutationsStartedAt"] = timestamp(); persistReport()
        try touch("like")
        try awaitAccount("Like toggled") { values($0,"likes").contains(id) != values(before,"likes").contains(id) }
        checked("Native Like toggle")
        try touch("save"); try touch("later")
        try awaitAccount("Watch Later toggled") { values($0,"later").contains(id) != values(before,"later").contains(id) }
        try closeSavePicker(); checked("Native Watch Later toggle and dialog closure"); try touch("follow")
        try awaitAccount("Follow toggled") { values($0,"follows").sorted() != values(before,"follows").sorted() }
        checked("Native speaker follow toggle")
        try awaitAccount("Playing lecture records real history") { $0["videoPlaying"] as? Bool == true && self.number($0,"videoTime") > 1 && values($0,"history").contains(id) }
        checked("Actual playing lecture history recorded")
        try touch("closeWatch")
        try touch("library"); try touch("playlists")
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
        try touch("like"); try touch("save"); try touch("later"); try closeSavePicker(); try touch("follow")
        try awaitAccount("Lecture flags restored") { values($0,"likes").contains(id) == values(before,"likes").contains(id) && values($0,"later").contains(id) == values(before,"later").contains(id) && values($0,"follows").sorted() == values(before,"follows").sorted() }
        checked("Lecture flags restored")
        try touch("closeWatch")
        try touch("account"); try touch("logout")
        try awaitAccount("Logout clears account state") { $0["loggedIn"] as? Bool == false && values($0,"likes").isEmpty && values($0,"later").isEmpty && ($0["playlists"] as? [[String:Any]] ?? []).isEmpty }
        checked("Logout clears account state")
        report["accountMutationsFinishedAt"] = timestamp(); report["status"] = "passed"; persistReport()
    }
