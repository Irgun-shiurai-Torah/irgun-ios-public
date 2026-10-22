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

    private func nativeKeyboardIsClosed() -> Bool {
        let native = snapshot()
        if native["nativeKeyboardObserved"] as? Bool == true {
            // Prefer a genuine UIKit hide event over a retained offscreen AX node.
            return native["nativeKeyboardVisible"] as? Bool == false
        }
        return !app.keyboards.firstMatch.exists
    }

    // Shared by comments, login, offline and cross-device regression tests.
    private func dismissNativeKeyboard() throws {
        func waitForClosure(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if nativeKeyboardIsClosed() { return true }
                RunLoop.current.run(until:Date().addingTimeInterval(0.2))
            }
            return nativeKeyboardIsClosed()
        }
        // Successful Post/Save blurs its own field asynchronously. Allow the
        // real UIKit hide notification to arrive before looking for accessories.
        if waitForClosure(3) { return }
        // WKWebView's Done accessory belongs to the app toolbar, not the
        // keyboard subtree. This is the same native control exercised by
        // the passing iPhone/iPad account suite. Return in a comment inserts
        // a newline; Go can submit a form, so neither is a dismissal action.
        for _ in 0..<2 {
            let toolbarDone = app.toolbars.buttons["Done"].firstMatch
            let appDone = app.buttons["Done"].firstMatch
            if toolbarDone.exists && toolbarDone.isHittable {
                toolbarDone.tap()
                if waitForClosure(5) { return }
            } else if appDone.exists && appDone.isHittable {
                appDone.tap()
                if waitForClosure(5) { return }
            }
            for label in ["Hide keyboard","Dismiss keyboard","Dismiss Keyboard"] {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable {
                    button.tap()
                    if waitForClosure(5) { return }
                }
            }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists && keyboard.isHittable {
                keyboard.swipeDown()
                if waitForClosure(3) { return }
            }
        }
        let native = snapshot()
        print("UITEST keyboard: observed=\(native["nativeKeyboardObserved"] ?? false) visible=\(native["nativeKeyboardVisible"] ?? false) eventAt=\(number(native,"nativeKeyboardObservedAt"))")
        XCTFail("Native keyboard remained visible after real accessory dismissal attempts")
        throw Failure.timedOut("keyboard dismissal")
    }
