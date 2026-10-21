    // Shared by account and extended suites. All entry and submission use
    // native XCTest keyboard/taps; observations only verify real form state.
    private func nativeEnterLoginField(_ key: String, _ value: String) throws {
        let password = key == "password"
        let focusedKey = password ? "authPasswordFocused" : "authEmailFocused"
        let lengthKey = password ? "authPasswordLength" : "authEmailLength"
        for _ in 0..<3 {
            let field = password ? app.webViews.secureTextFields.firstMatch : app.webViews.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout:10),"Real native login field must exist")
            // A failed sign-in deliberately preserves the email. Do not erase
            // and retype an already-correct address: UIKit may place the caret
            // at the start of a filled text field, so backspaces cannot clear it.
            // Confirm BOTH the native field text and actual observed input state.
            if !password {
                let observed = snapshot()["account"] as? [String:Any] ?? [:]
                let actual = (field.value as? String ?? "")
                    .trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                let wanted = value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                if actual == wanted &&
                    Int(number(observed,lengthKey)) == value.utf16.count &&
                    observed["authEmailValid"] as? Bool == true { return }
            }
            field.tap()
            _ = try waitFor("Native login field receives focus before keyboard entry",timeout:15) {
                ($0["account"] as? [String:Any])?[focusedKey] as? Bool == true
            }
            _ = app.keyboards.firstMatch.waitForExistence(timeout:2)
            let account = snapshot()["account"] as? [String:Any] ?? [:]
            let existingLength = Int(number(account,lengthKey))
            if existingLength > 0 {
                // Aim at the trailing end before deleting, rather than the
                // field's midpoint which can position the caret at its start.
                field.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
                field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,
                                      count:existingLength+8))
                _ = try waitFor("Native keyboard clears only the focused login field",timeout:10) {
                    self.number($0["account"] as? [String:Any] ?? [:],lengthKey) == 0
                }
            }
            field.typeText(value)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let observed = snapshot()["account"] as? [String:Any] ?? [:]
                let lengthMatches = Int(number(observed,lengthKey)) == value.utf16.count
                let emailMatches = password || (field.value as? String ?? "")
                    .trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == value
                    .trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
                if lengthMatches && emailMatches { return }
                RunLoop.current.run(until:Date().addingTimeInterval(0.2))
            }
        }
        XCTFail("Native credential entry did not match the approved field shape; no login was submitted")
        throw Failure.timedOut("Native credential entry")
    }

    private func nativeSubmitLoginForm() throws {
        let before = number(snapshot()["account"] as? [String:Any] ?? [:],"authSubmitCount")
        var submitted = false
        // Do not press Go/Return while credentials are still being entered or
        // repaired: a premature request clears the secure field on rerender.
        for label in ["Go","Log In","Return","return"] {
            let key = app.keyboards.buttons[label].firstMatch
            if key.exists && key.isHittable { key.tap();submitted=true;break }
        }
        if !submitted { try tapWebButton("Login") }
        _ = try waitFor("The real native login form must submit",timeout:20) {
            let account = $0["account"] as? [String:Any] ?? [:]
            return account["loggedIn"] as? Bool == true ||
                self.number(account,"authSubmitCount") > before
        }
    }

    // Shared by comments, login, offline and cross-device regression tests.
    private func dismissNativeKeyboard() throws {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        // Prefer a real swipe-down first. Avoid a global Done-button query,
        // which can race with the keyboard disappearing during accessibility polling.
        if keyboard.isHittable { keyboard.swipeDown() }
        var deadline = Date().addingTimeInterval(3)
        while Date() < deadline && app.keyboards.firstMatch.exists {
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        }
        if !app.keyboards.firstMatch.exists { return }
        for label in ["Done","Return","Go","Log In"] {
            let key = app.keyboards.buttons[label].firstMatch
            if key.exists && key.isHittable {
                key.tap()
                deadline = Date().addingTimeInterval(3)
                while Date() < deadline && app.keyboards.firstMatch.exists {
                    RunLoop.current.run(until:Date().addingTimeInterval(0.2))
                }
                if !app.keyboards.firstMatch.exists { return }
                break
            }
        }
        if app.keyboards.firstMatch.exists {
            // Final outside tap in the app's top margin, not on the text field.
            let frame = app.frame
            if frame.width > 0 && frame.height > 40 {
                app.coordinate(withNormalizedOffset:.zero).withOffset(
                    CGVector(dx:frame.width*0.5,dy:24)).tap()
            }
        }
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline && app.keyboards.firstMatch.exists {
            RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        }
        guard !app.keyboards.firstMatch.exists else {
            XCTFail("Native keyboard remained visible after dismissal attempts")
            throw Failure.timedOut("keyboard dismissal")
        }
    }
