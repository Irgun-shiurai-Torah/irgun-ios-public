import UIKit
import Capacitor

// Simulator-only scene migration for screenshot validation with the iOS 27 SDK.
// The shipping iOS 26 build is not changed by this file.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowApplication,
              let windowScene = scene as? UIWindowScene else { return }
        let appWindow = UIWindow(windowScene: windowScene)
        let bridgeController = CAPBridgeViewController()
        let isUnfoldedDuoCapture = ProcessInfo.processInfo.arguments.contains("--irgun-duo-unfolded")
        bridgeController.supportedOrientations = isUnfoldedDuoCapture
            ? [UIInterfaceOrientation.landscapeLeft.rawValue, UIInterfaceOrientation.landscapeRight.rawValue]
            : [UIInterfaceOrientation.portrait.rawValue]
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
        if let bridgeController = window?.rootViewController as? CAPBridgeViewController {
            bridgeController.supportedOrientations = isUnfoldedDuoCapture
                ? [UIInterfaceOrientation.landscapeLeft.rawValue, UIInterfaceOrientation.landscapeRight.rawValue]
                : [UIInterfaceOrientation.portrait.rawValue]
        }
        appDelegate.irgunSetVideoOrientationMask(targetMask)
        if #available(iOS 16.0, *) {
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if let activeScene = scene as? UIWindowScene {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    activeScene.requestGeometryUpdate(
                        .iOS(interfaceOrientations: targetMask)
                    ) { error in
                        NSLog("IST Duo screenshot orientation request failed: \\(error)")
                    }
                }
            }
        } else {
            // Keep the simulator-only helper compatible with the app's iOS 15
            // deployment target. iOS 16+ uses explicit scene geometry above.
            UIViewController.attemptRotationToDeviceOrientation()
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
