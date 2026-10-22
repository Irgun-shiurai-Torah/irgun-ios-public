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
        appWindow.rootViewController = CAPBridgeViewController()
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
