#if targetEnvironment(simulator)
import UIKit
import WebKit
import Capacitor
import Network

// Compiled into CI simulator builds only; never copied by the release workflow.
final class SimulatorProbe {
    static let shared = SimulatorProbe()
    private weak var window: UIWindow?
    private var panel: UIView?
    private var status: UILabel?
    private var timer: Timer?
    private var polling = false
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
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "ist-simulator-status"
        label.accessibilityLabel = "Simulator playback status"
        label.accessibilityValue = "{}"
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
        let buttons = UIStackView(arrangedSubviews: [button, reopen, next, hide, controls])
        buttons.axis = .horizontal; buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for control in [button, reopen, next, hide, controls] { control.titleLabel?.font = .systemFont(ofSize: 10) }
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

    @objc private func openSample() {
        webView?.evaluateJavaScript("window.ISTSimulator?.openSample()", completionHandler: nil)
    }

    @objc private func reopenCurrent() {
        webView?.evaluateJavaScript("window.ISTSimulator?.reopenCurrent()", completionHandler: nil)
    }

    @objc private func nextStorePage() { webView?.evaluateJavaScript("window.ISTSimulator?.nextStorePage()", completionHandler: nil) }
    @objc private func cleanCapture() {
        panel?.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.panel?.isHidden = false }
    }
    @objc private func hideForAppControls() {
        panel?.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.panel?.isHidden = false }
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
                if let merged = try? JSONSerialization.data(withJSONObject: state), let value = String(data: merged, encoding: .utf8) {
                    self.status?.accessibilityValue = value
                    self.observationLock.lock()
                    self.observation = merged + Data([10])
                    self.observationLock.unlock()
                }
            }
        }
    }
}
#endif
