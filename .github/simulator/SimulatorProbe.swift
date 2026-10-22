#if targetEnvironment(simulator)
import UIKit
import WebKit
import Capacitor
import Network
import UserNotifications

// Compiled into CI simulator builds only; never copied by the release workflow.
final class SimulatorProbe {
    static let shared = SimulatorProbe()
    private weak var window: UIWindow?
    private var panel: UIView?
    private var status: UILabel?
    private var timer: Timer?
    private var polling = false
    private var nativePushAuthorized = false
    private var notificationObservers = [NSObjectProtocol]()
    private var nativeBackgroundCount = 0
    private var nativeLifecycleObservedAt = 0.0
    private var nativeKeyboardObserved = false
    private var nativeKeyboardVisible = false
    private var nativeKeyboardObservedAt = 0.0
    private var nativeKeyboardFrame = CGRect.null
    private var latestState = [String:Any]()
    private var listener: NWListener?
    private let observationQueue = DispatchQueue(label: "org.irgun.simulator.observations")
    private let observationLock = NSLock()
    private var observation = Data("{}\n".utf8)

    func install(in window: UIWindow?) {
        guard ProcessInfo.processInfo.arguments.contains("--irgun-simulator-tests"),
              panel == nil, let window = window else { return }
        self.window = window
        let panel = UIView()
        panel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        panel.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "Simulator diagnostics"
        label.font = .systemFont(ofSize: 9)
        // Full observations travel over loopback. Publishing the same large,
        // changing JSON value into AX makes each native UI query serialize it.
        label.isAccessibilityElement = false
        label.accessibilityIdentifier = "ist-simulator-status"
        label.accessibilityLabel = "Simulator playback status"
        label.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.setTitle("Open HLS test shiur", for: .normal)
        button.accessibilityIdentifier = "ist-simulator-open"
        button.addTarget(self, action: #selector(openSample), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        let reopen = UIButton(type: .system)
        reopen.setTitle("Reopen shiur", for: .normal)
        reopen.accessibilityIdentifier = "ist-simulator-reopen"
        reopen.addTarget(self, action: #selector(reopenCurrent), for: .touchUpInside)
        reopen.translatesAutoresizingMaskIntoConstraints = false
        let next = UIButton(type: .system)
        next.setTitle("Next page", for: .normal)
        next.accessibilityIdentifier = "ist-simulator-next-page"
        next.addTarget(self, action: #selector(nextStorePage), for: .touchUpInside)
        let hide = UIButton(type: .system)
        hide.setTitle("Clean capture", for: .normal)
        hide.accessibilityIdentifier = "ist-simulator-clean-capture"
        hide.addTarget(self, action: #selector(cleanCapture), for: .touchUpInside)
        let controls = UIButton(type: .system)
        controls.setTitle("Hide controls", for: .normal)
        controls.accessibilityIdentifier = "ist-simulator-hide-controls"
        controls.addTarget(self, action: #selector(hideForAppControls), for: .touchUpInside)
        let push = UIButton(type: .system)
        push.setTitle("Enable Push", for: .normal)
        push.accessibilityIdentifier = "ist-simulator-enable-push"
        push.addTarget(self, action: #selector(enablePushPermission), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [button, reopen, next, hide, controls, push])
        buttons.axis = .horizontal; buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for control in [button, reopen, next, hide, controls, push] { control.titleLabel?.font = .systemFont(ofSize: 10) }
        panel.addSubview(label)
        panel.addSubview(buttons)
        window.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            panel.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor),
            panel.heightAnchor.constraint(equalToConstant: 54),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 34)
        ])
        self.panel = panel
        self.status = label
        observeNativeState()
        startObservations()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private var webView: WKWebView? {
        (window?.rootViewController as? CAPBridgeViewController)?.webView
    }

    // A simulator-only loopback observation channel avoids Xcode's intermittent
    // stale AX snapshots of a rapidly changing, large accessibility value.
    // All actions still use real UI gestures; this channel only reads state.
    private func startObservations() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47291)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self = self else { return }
                self.observationLock.lock()
                let data = self.observation
                self.observationLock.unlock()
                connection.send(content: data, completion: .contentProcessed { _ in connection.stateUpdateHandler = nil; connection.cancel() })
            }
            connection.start(queue: self?.observationQueue ?? .global())
        }
        listener.start(queue: observationQueue)
    }

    // UIKit notifications are independent of WebKit's JS timer and XCTest's
    // cached accessibility tree. Publish them immediately, including while the
    // app's real audio background mode keeps the observation listener alive.
    private func observeNativeState() {
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification,
                     UIApplication.didBecomeActiveNotification,
                     UIApplication.willResignActiveNotification] {
            notificationObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] event in
                guard let self = self else { return }
                if event.name == UIApplication.didEnterBackgroundNotification { self.nativeBackgroundCount += 1 }
                self.nativeLifecycleObservedAt = Date().timeIntervalSince1970 * 1000
                self.publishObservation()
            })
        }
        for name in [UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardDidHideNotification] {
            notificationObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] event in
                guard let self = self else { return }
                self.nativeKeyboardObserved = true
                self.nativeKeyboardObservedAt = Date().timeIntervalSince1970 * 1000
                if event.name == UIResponder.keyboardDidHideNotification {
                    self.nativeKeyboardVisible = false
                } else if let frame = event.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                          let window = self.window {
                    let local = window.convert(frame,from:nil)
                    self.nativeKeyboardFrame = local
                    let intersection = window.bounds.intersection(local)
                    self.nativeKeyboardVisible = !intersection.isNull && intersection.height > 1 && intersection.width > 1
                }
                self.publishObservation()
            })
        }
    }

    private func publishObservation() {
        var state = latestState
        state["nativeApplicationState"] = UIApplication.shared.applicationState.rawValue
        state["nativeBackgroundCount"] = nativeBackgroundCount
        state["nativeLifecycleObservedAt"] = nativeLifecycleObservedAt
        state["nativeKeyboardObserved"] = nativeKeyboardObserved
        state["nativeKeyboardVisible"] = nativeKeyboardVisible
        state["nativeKeyboardObservedAt"] = nativeKeyboardObservedAt
        if !nativeKeyboardFrame.isNull {
            state["nativeKeyboardFrame"] = ["x":Double(nativeKeyboardFrame.minX),
                "y":Double(nativeKeyboardFrame.minY),"width":Double(nativeKeyboardFrame.width),
                "height":Double(nativeKeyboardFrame.height)]
        }
        state["nativeDiagnosticsVisible"] = panel?.isHidden == false
        state["nativeObservationPublishedAt"] = Date().timeIntervalSince1970 * 1000
        if let merged = try? JSONSerialization.data(withJSONObject: state) {
            observationLock.lock()
            observation = merged + Data([10])
            observationLock.unlock()
        }
    }

    @objc private func enablePushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    self?.nativePushAuthorized = granted &&
                        (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                    self?.poll()
                }
            }
        }
    }

    @objc private func openSample() {
        let action = ProcessInfo.processInfo.arguments.contains("--irgun-reported-mp4") ? "openReportedShiur" : "openSample"
        webView?.evaluateJavaScript("window.ISTSimulator?.\(action)()", completionHandler: nil)
    }

    @objc private func reopenCurrent() {
        webView?.evaluateJavaScript("window.ISTSimulator?.reopenCurrent()", completionHandler: nil)
    }

    @objc private func nextStorePage() { webView?.evaluateJavaScript("window.ISTSimulator?.nextStorePage()", completionHandler: nil) }
    @objc private func cleanCapture() {
        panel?.isHidden = true
        publishObservation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.panel?.isHidden = false
            self?.publishObservation()
        }
    }
    @objc private func hideForAppControls() {
        // Keep diagnostics out of the app's touch path for the rest of this
        // test. A timed return can cover the fullscreen toolbar between its
        // observed hit test and XCTest delivering the real touch. Each test
        // relaunches the app and recreates the panel.
        panel?.isHidden = true
    }

    private func poll() {
        guard !polling, let webView = webView else { return }
        polling = true
        webView.evaluateJavaScript("window.ISTSimulator?.snapshot() || '{}'") { [weak self] result, error in
            guard let self = self else { return }
            self.polling = false
            if let json = result as? String, let data = json.data(using: .utf8),
               var state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                state["nativeAudio"] = IrgunBackgroundAudioPlugin.current?.snapshot() ?? [:]
                state["nativePlayer"] = IrgunUnifiedPlayerPlugin.current?.simulatorSnapshot() ?? [:]
                state["nativePushAuthorized"] = self.nativePushAuthorized
                self.latestState = state
                self.publishObservation()
            }
        }
    }
}
#endif
