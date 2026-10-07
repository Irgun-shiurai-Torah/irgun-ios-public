    // Credentials come from private GitHub secrets through the ephemeral test scheme.
    func testLoggedInAccountPersistenceAndLogout() throws {
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
        try touch("account")
        try touch("email"); app.textFields.firstMatch.typeText(email)
        try touch("password"); app.secureTextFields.firstMatch.typeText(password + "\n")
        if account()["loggedIn"] as? Bool != true { try touch("login") }
        try awaitAccount("Native login and profile") { $0["loggedIn"] as? Bool == true && $0["profileVisible"] as? Bool == true }
        XCTAssertEqual(account()["isAdmin"] as? Bool, false, "Use a dedicated non-admin account")
        XCTAssertTrue((account()["name"] as? String ?? "").hasPrefix("Irgun QA "), "Refuse to mutate a personal account")
        try touch("settings")
        try awaitAccount("Settings displayed") { $0["settingsVisible"] as? Bool == true }
        try touch("shiurim"); try touch("open")
        try awaitAccount("Lecture opened") { !($0["watchId"] as? String ?? "").isEmpty }
        let id=account()["watchId"] as! String, before=account()
        try touch("like")
        try awaitAccount("Like toggled") { values($0,"likes").contains(id) != values(before,"likes").contains(id) }
        try touch("save"); try touch("later")
        try awaitAccount("Watch Later toggled") { values($0,"later").contains(id) != values(before,"later").contains(id) }
        try touch("closePicker"); try touch("follow")
        try awaitAccount("Follow toggled") { values($0,"follows").sorted() != values(before,"follows").sorted() }
        try awaitAccount("Playing lecture records real history") { $0["videoPlaying"] as? Bool == true && self.number($0,"videoTime") > 1 }
        try touch("closeWatch")
        try touch("library"); try touch("playlists")
        let playlistName="Irgun-QA-\(Int(Date().timeIntervalSince1970))"
        try touch("playlistName"); app.textFields.firstMatch.typeText(playlistName + "\n")
        func hasPlaylist(_ s:[String:Any]) -> Bool { (s["playlists"] as? [[String:Any]] ?? []).contains { $0["name"] as? String == playlistName } }
        try awaitAccount("Playlist created") { hasPlaylist($0) }
        let changed=account()
        app.terminate(); app.launch()
        try awaitAccount("Session and playlist survive process restart") { $0["ready"] as? Bool == true && $0["loggedIn"] as? Bool == true && hasPlaylist($0) }
        XCTAssertEqual(values(account(),"likes").contains(id),values(changed,"likes").contains(id))
        XCTAssertEqual(values(account(),"later").contains(id),values(changed,"later").contains(id))
        XCTAssertEqual(values(account(),"follows").sorted(),values(changed,"follows").sorted())
        XCTAssertTrue(values(account(),"history").contains(id),"Playback history must survive relaunch")
        evidence("logged-in-account-restored")
        // Restore the lecture flags. Keep the uniquely named QA playlist for inspection.
        try touch("shiurim"); try touch("open")
        try awaitAccount("Same lecture for cleanup") { $0["watchId"] as? String == id }
        try touch("like"); try touch("save"); try touch("later"); try touch("closePicker"); try touch("follow"); try touch("closeWatch")
        try touch("account"); try touch("logout")
        try awaitAccount("Logout clears account state") { $0["loggedIn"] as? Bool == false && values($0,"likes").isEmpty && values($0,"later").isEmpty && ($0["playlists"] as? [[String:Any]] ?? []).isEmpty }
    }
