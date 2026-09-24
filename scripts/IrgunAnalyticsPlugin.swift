import Foundation
import Capacitor
import UIKit

@objc(IrgunAnalyticsPlugin)
public class IrgunAnalyticsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "IrgunAnalyticsPlugin"
    public let jsName = "IrgunAnalytics"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDeviceId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "event", returnType: CAPPluginReturnPromise)
    ]

    private let apiBase = URL(string: "https://api.irgunshiuraitorah.com")!
    private let defaultsKey = "irgun_usage_analytics_anonymous_device_id_v1"
    private let stateQueue = DispatchQueue(label: "org.irgunshiuraitorah.analytics.state")
    private let networkQueue = DispatchQueue(label: "org.irgunshiuraitorah.analytics.network", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var foreground = true
    private var configured = true
    private var appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "ios"
    private var screen = "App"
    private var mediaType = "none"
    private var playerState = "browsing"
    private var shiurId: String?
    private var isPlaying = false
    private var pipActive = false
    private let instanceId = UUID().uuidString.lowercased()
    private lazy var deviceId: String = Self.loadOrCreateDeviceId(key: defaultsKey)

    override public func load() {
        foreground = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(true)
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(false)
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopTimer()
        })
        startTimer()
    }

    deinit {
        stopTimer()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc func configure(_ call: CAPPluginCall) {
        let version = sanitize(call.getString("appVersion"), max: 48)
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let version, !version.isEmpty { self.appVersion = version }
            self.configured = true
            self.sendPresence(force: true)
        }
        call.resolve(["deviceId": deviceId])
    }

    @objc func getDeviceId(_ call: CAPPluginCall) {
        call.resolve(["deviceId": deviceId])
    }

    @objc func setState(_ call: CAPPluginCall) {
        let nextScreen = sanitize(call.getString("screen"), max: 80)
        let nextMedia = sanitizeMedia(call.getString("mediaType"))
        let nextState = sanitizePlayerState(call.getString("playerState"))
        let nextShiur = sanitize(call.getString("shiurId"), max: 120)
        let nextPlaying = call.getBool("isPlaying") ?? false
        let nextPip = call.getBool("pipActive") ?? false

        stateQueue.async { [weak self] in
            guard let self else { return }
            let changed = self.screen != (nextScreen ?? self.screen)
                || self.mediaType != nextMedia
                || self.playerState != nextState
                || self.shiurId != nextShiur
                || self.isPlaying != nextPlaying
                || self.pipActive != nextPip
            if let nextScreen, !nextScreen.isEmpty { self.screen = nextScreen }
            self.mediaType = nextMedia
            self.playerState = nextState
            self.shiurId = nextShiur
            self.isPlaying = nextPlaying
            self.pipActive = nextPip
            if changed { self.sendPresence(force: true) }
        }
        call.resolve()
    }

    @objc func event(_ call: CAPPluginCall) {
        guard let eventType = sanitize(call.getString("eventType"), max: 48), !eventType.isEmpty else {
            call.resolve()
            return
        }
        let eventId = sanitize(call.getString("eventId"), max: 100) ?? UUID().uuidString.lowercased()
        let eventShiur = sanitize(call.getString("shiurId"), max: 120)
        let eventMedia = sanitizeMedia(call.getString("mediaType"))
        let eventScreen = sanitize(call.getString("screen"), max: 80)

        let payload: [String: Any] = [
            "deviceId": deviceId,
            "instanceId": instanceId,
            "platform": "ios",
            "eventId": eventId,
            "eventType": eventType,
            "shiurId": eventShiur ?? "",
            "mediaType": eventMedia,
            "screen": eventScreen ?? screen,
            "appVersion": appVersion
        ]
        post(path: "/analytics/event", payload: payload)
        call.resolve()
    }

    private func setForeground(_ active: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.foreground = active
            self.sendPresence(force: true)
        }
    }

    private func startTimer() {
        stateQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
            timer.schedule(deadline: .now() + 3, repeating: 30, leeway: .seconds(3))
            timer.setEventHandler { [weak self] in self?.sendPresence(force: false) }
            self.timer = timer
            timer.resume()
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func sendPresence(force: Bool) {
        if !configured && !force { return }
        if !foreground && !isPlaying { return }

        var effectiveScreen = screen
        if !foreground && isPlaying {
            if mediaType == "audio" { effectiveScreen = "Background audio" }
            else if mediaType == "video" && pipActive { effectiveScreen = "Picture in Picture" }
            else if mediaType == "video" { effectiveScreen = "Background video" }
        }

        let payload: [String: Any] = [
            "deviceId": deviceId,
            "instanceId": instanceId,
            "platform": "ios",
            "screen": effectiveScreen,
            "mediaType": mediaType,
            "playerState": isPlaying ? "playing" : playerState,
            "isPlaying": isPlaying,
            "shiurId": shiurId ?? "",
            "appVersion": appVersion
        ]
        post(path: "/analytics/presence", payload: payload)
    }

    private func post(path: String, payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload) else { return }
        networkQueue.async { [apiBase] in
            guard let url = URL(string: path, relativeTo: apiBase),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.timeoutInterval = 4
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 6
            config.waitsForConnectivity = false
            URLSession(configuration: config).dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    private static func loadOrCreateDeviceId(key: String) -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.count >= 12 {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    private func sanitize(_ value: String?, max: Int) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.components(separatedBy: CharacterSet.controlCharacters).joined()
        if text.count > max { text = String(text.prefix(max)) }
        return text
    }

    private func sanitizeMedia(_ value: String?) -> String {
        switch value?.lowercased() {
        case "video": return "video"
        case "audio": return "audio"
        default: return "none"
        }
    }

    private func sanitizePlayerState(_ value: String?) -> String {
        switch value?.lowercased() {
        case "playing": return "playing"
        case "paused": return "paused"
        default: return "browsing"
        }
    }
}
