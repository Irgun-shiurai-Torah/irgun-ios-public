import UIKit
import Capacitor

// The Duo capture app must advertise its desired orientation from the root
// controller itself. Capacitor normally derives this from Info.plist, and the
// Duo simulator can otherwise reset the unfolded inner panel to portrait.
private final class DuoCaptureBridgeViewController: CAPBridgeViewController {
    private let forceLandscape = ProcessInfo.processInfo.arguments.contains("--irgun-duo-unfolded")

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        forceLandscape ? .landscape : .portrait
    }

    override var shouldAutorotate: Bool { true }
}

// Simulator-only scene migration for screenshot validation with the iOS 27 SDK.
// The shipping iOS 26 build is not changed by this file.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowApplication,
              let windowScene = scene as? UIWindowScene else { return }
        let appWindow = UIWindow(windowScene: windowScene)
        let bridgeController = DuoCaptureBridgeViewController()
        appWindow.rootViewController = bridgeController
        window = appWindow
        (UIApplication.shared.delegate as? AppDelegate)?.window = appWindow
        appWindow.makeKeyAndVisible()
        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.window = window
        appDelegate.irgunConfigurePlaybackAudioSession()
        appDelegate.irgunInstallAudioSessionObservers()
        appDelegate.irgunApplyWebViewMediaAndZoomPolicy()
        appDelegate.irgunScheduleAnalyticsPluginRegistration()
        appDelegate.irgunDispatchWebLifecycleEvent("irgunNativeDidBecomeActive")
        #if targetEnvironment(simulator)
        SimulatorProbe.shared.install(in: window)
        #endif

        // The Duo simulator can reset to portrait when XCTest launches the app,
        // even if the Device Hub orientation was set before launch. Set the
        // Capacitor root controller's supported orientations first (in
        // willConnectTo), then request the matching live scene geometry here.
        // This file is injected only into the disposable Duo screenshot build.
        let isUnfoldedDuoCapture = ProcessInfo.processInfo.arguments.contains("--irgun-duo-unfolded")
        let targetMask: UIInterfaceOrientationMask = isUnfoldedDuoCapture ? .landscape : .portrait
        appDelegate.irgunSetVideoOrientationMask(targetMask)
        if #available(iOS 16.0, *) {
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if let activeScene = scene as? UIWindowScene {
                // iOS 27's Duo simulator can reapply portrait after XCTest launches
                // the app. Reassert the geometry until UIKit reports the requested
                // scene orientation, rather than trusting a single early request.
                requestOrientation(activeScene, mask: targetMask, attempt: 0)
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    @available(iOS 16.0, *)
    private func requestOrientation(_ scene: UIWindowScene,
                                    mask: UIInterfaceOrientationMask,
                                    attempt: Int) {
        guard attempt < 10, scene.activationState == .foregroundActive else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            NSLog("IST Duo screenshot orientation request failed (attempt \\(attempt)): \\(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak scene] in
            guard let self = self, let scene = scene,
                  scene.activationState == .foregroundActive else { return }
            let wantsLandscape = mask.contains(.landscape)
            if scene.interfaceOrientation.isLandscape == wantsLandscape { return }
            self.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            self.requestOrientation(scene, mask: mask, attempt: attempt + 1)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?
            .irgunDispatchWebLifecycleEvent("irgunNativeWillResignActive")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?
            .irgunDispatchWebLifecycleEvent("irgunNativeBackground")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?
            .irgunDispatchWebLifecycleEvent("irgunNativeForeground")
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
