#if targetEnvironment(simulator)
import UIKit
import WebKit
import Capacitor

// Compiled into CI simulator builds only; never copied by the release workflow.
final class SimulatorProbe {
    static let shared = SimulatorProbe()
    private weak var window: UIWindow?
    private var panel: UIView?
    private var status: UILabel?
    private var timer: Timer?
    private var polling = false

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
        panel.addSubview(label)
        panel.addSubview(button)
        window.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor),
            panel.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        ])
        self.panel = panel
        self.status = label
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private var webView: WKWebView? {
        (window?.rootViewController as? CAPBridgeViewController)?.webView
    }

    @objc private func openSample() {
        webView?.evaluateJavaScript("window.ISTSimulator?.openSample()", completionHandler: nil)
    }

    private func poll() {
        guard !polling, let webView = webView else { return }
        polling = true
        webView.evaluateJavaScript("window.ISTSimulator?.snapshot() || '{}'") { [weak self] result, error in
            guard let self = self else { return }
            self.polling = false
            if let json = result as? String { self.status?.accessibilityValue = json }
        }
    }
}
#endif
