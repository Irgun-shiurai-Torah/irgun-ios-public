#!/usr/bin/env python3
import base64
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_APP = ROOT / 'ios' / 'App' / 'App'
INFO = IOS_APP / 'Info.plist'
ENTITLEMENTS = IOS_APP / 'App.entitlements'
GOOGLE_PLIST = IOS_APP / 'GoogleService-Info.plist'
EMBEDDED_GOOGLE_PLIST = ROOT / 'GoogleService-Info.plist'
BUNDLE_ID = os.environ.get('BUNDLE_ID', 'org.irgunshiuraitorah.app').strip()
MARKETING_VERSION = os.environ.get('IOS_MARKETING_VERSION', '1.0.0').strip()
BUILD_NUMBER = os.environ.get('IOS_RESOLVED_BUILD_NUMBER', os.environ.get('BUILD_NUMBER', os.environ.get('CM_BUILD_ID', '1'))).strip()
ANALYTICS_PLUGIN_TEMPLATE = ROOT / 'scripts' / 'IrgunAnalyticsPlugin.swift'
ANALYTICS_PLUGIN = IOS_APP / 'IrgunAnalyticsPlugin.swift'

def die(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(2)

def decode_firebase_plist():
    encoded = os.environ.get('GOOGLE_SERVICE_INFO_PLIST_BASE64', '').strip()
    raw_path = os.environ.get('GOOGLE_SERVICE_INFO_PLIST_PATH', '').strip()
    if encoded:
        try:
            GOOGLE_PLIST.write_bytes(base64.b64decode(encoded))
        except Exception as exc:
            die(f'Could not decode GOOGLE_SERVICE_INFO_PLIST_BASE64: {exc}')
    elif raw_path:
        source = Path(raw_path).expanduser()
        if not source.exists():
            die(f'GOOGLE_SERVICE_INFO_PLIST_PATH does not exist: {source}')
        GOOGLE_PLIST.write_bytes(source.read_bytes())
    elif EMBEDDED_GOOGLE_PLIST.exists():
        GOOGLE_PLIST.write_bytes(EMBEDDED_GOOGLE_PLIST.read_bytes())
    elif GOOGLE_PLIST.exists():
        pass
    else:
        die('GoogleService-Info.plist is required. Keep the Firebase iOS plist at the project root, or provide GOOGLE_SERVICE_INFO_PLIST_BASE64 / GOOGLE_SERVICE_INFO_PLIST_PATH in Codemagic.')

    try:
        with GOOGLE_PLIST.open('rb') as fh:
            data = plistlib.load(fh)
    except Exception as exc:
        die(f'GoogleService-Info.plist is invalid: {exc}')

    plist_bundle = str(data.get('BUNDLE_ID') or '').strip()
    if plist_bundle and plist_bundle != BUNDLE_ID:
        die(f'Firebase plist bundle ID is {plist_bundle}, expected {BUNDLE_ID}. Create the Firebase iOS app with the exact Irgun bundle ID.')
    ios_client = str(data.get('CLIENT_ID') or '').strip()
    reversed_client = str(data.get('REVERSED_CLIENT_ID') or '').strip()
    if not ios_client or not reversed_client:
        die('Firebase plist is missing CLIENT_ID or REVERSED_CLIENT_ID. Enable/add Google sign-in for the iOS app and download a fresh plist.')
    return ios_client, reversed_client

def patch_info_plist(ios_client, reversed_client):
    if not INFO.exists():
        die(f'Capacitor iOS project is missing {INFO}. Run npx cap add ios before this script.')
    with INFO.open('rb') as fh:
        data = plistlib.load(fh)

    data['CFBundleDisplayName'] = 'Irgun Shiurai Torah'
    data['GIDClientID'] = ios_client
    data['ITSAppUsesNonExemptEncryption'] = False
    data['FirebaseMessagingAutoInitEnabled'] = True
    data.pop('NSCameraUsageDescription', None)

    modes = list(data.get('UIBackgroundModes') or [])
    if 'remote-notification' not in modes:
        modes.append('remote-notification')
    if 'audio' not in modes:
        modes.append('audio')
    data['UIBackgroundModes'] = modes

    url_types = list(data.get('CFBundleURLTypes') or [])
    existing_schemes = set()
    for item in url_types:
        for scheme in item.get('CFBundleURLSchemes') or []:
            existing_schemes.add(str(scheme))
    if reversed_client not in existing_schemes:
        url_types.append({
            'CFBundleTypeRole': 'Editor',
            'CFBundleURLSchemes': [reversed_client],
        })
    data['CFBundleURLTypes'] = url_types

    with INFO.open('wb') as fh:
        plistlib.dump(data, fh, sort_keys=False)

def write_entitlements():
    data = {
        'com.apple.developer.applesignin': ['Default'],
        'aps-environment': 'production',
    }
    with ENTITLEMENTS.open('wb') as fh:
        plistlib.dump(data, fh, sort_keys=False)


def write_analytics_plugin():
    if not ANALYTICS_PLUGIN_TEMPLATE.exists():
        die(f'Analytics plugin template is missing: {ANALYTICS_PLUGIN_TEMPLATE}')
    ANALYTICS_PLUGIN.write_text(ANALYTICS_PLUGIN_TEMPLATE.read_text())

def patch_app_delegate():
    app_delegate = IOS_APP / 'AppDelegate.swift'
    if not app_delegate.exists():
        die(f'AppDelegate.swift is missing at {app_delegate}')
    text = app_delegate.read_text()

    if 'import WebKit' not in text:
        if 'import Capacitor' in text:
            text = text.replace('import Capacitor', 'import Capacitor\nimport WebKit', 1)
        else:
            text = text.replace('import UIKit', 'import UIKit\nimport WebKit', 1)

    additions = []
    if 'private var irgunAnalyticsPlugin: IrgunAnalyticsPlugin?' not in text:
        class_match = re.search(r'class\s+AppDelegate[^\{]*\{', text)
        if not class_match:
            die('Could not find AppDelegate class declaration')
        insertion_point = class_match.end()
        text = text[:insertion_point] + '\n    private var irgunAnalyticsPlugin: IrgunAnalyticsPlugin?\n' + text[insertion_point:]

    if 'private func irgunRegisterAnalyticsPlugin()' not in text:
        additions.append("""
    private func irgunRegisterAnalyticsPlugin() {
        guard irgunAnalyticsPlugin == nil,
              let bridgeVC = window?.rootViewController as? CAPBridgeViewController,
              let capacitorBridge = bridgeVC.bridge as? CapacitorBridge else { return }
        let plugin = IrgunAnalyticsPlugin()
        capacitorBridge.registerPluginInstance(plugin)
        irgunAnalyticsPlugin = plugin
    }

    private func irgunScheduleAnalyticsPluginRegistration() {
        irgunRegisterAnalyticsPlugin()
        for delay in [0.15, 0.45, 1.00] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.irgunRegisterAnalyticsPlugin()
            }
        }
    }
""")

    if 'capacitorDidRegisterForRemoteNotifications' not in text:
        additions.append('''
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Notification.Name.init("didReceiveRemoteNotification"), object: completionHandler, userInfo: userInfo)
    }
''')

    if 'private func irgunApplyWebViewMediaAndZoomPolicy()' not in text:
        additions.append('''
    private func irgunApplyWebViewMediaAndZoomPolicy() {
        let applyPolicy: () -> Void = { [weak self] in
            guard let bridgeVC = self?.window?.rootViewController as? CAPBridgeViewController,
                  let webView = bridgeVC.webView else { return }
            webView.configuration.allowsPictureInPictureMediaPlayback = true
            webView.configuration.allowsInlineMediaPlayback = true
            // Allow the already user-initiated async Audio -> Video handoff
            // to resume after HLS source discovery without requiring a second tap.
            webView.configuration.mediaTypesRequiringUserActionForPlayback = []
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
            webView.scrollView.minimumZoomScale = 1.0
            webView.scrollView.maximumZoomScale = 1.0
            webView.scrollView.setZoomScale(1.0, animated: false)
            bridgeVC.view.setNeedsLayout()
            bridgeVC.view.layoutIfNeeded()
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
        }
        DispatchQueue.main.async(execute: applyPolicy)
        for delay in [0.12, 0.35, 0.80] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: applyPolicy)
        }
    }

    private func irgunDispatchWebLifecycleEvent(_ name: String) {
        guard let bridgeVC = window?.rootViewController as? CAPBridgeViewController,
              let webView = bridgeVC.webView else { return }
        let safeName = name.replacingOccurrences(of: "'", with: "")
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('\(safeName)'))", completionHandler: nil)
    }
''')

    if additions:
        idx = text.rfind('\n}')
        if idx < 0:
            die('Could not find the end of AppDelegate.swift')
        text = text[:idx] + ''.join(additions) + text[idx:]

    # Dispatch native lifecycle transitions into the WebView before iOS suspends it.
    for method_name, event_name in [
        ('applicationWillResignActive', 'irgunNativeWillResignActive'),
        ('applicationDidEnterBackground', 'irgunNativeBackground'),
        ('applicationWillEnterForeground', 'irgunNativeForeground'),
    ]:
        lifecycle_match = re.search(rf'func {method_name}\(_ application: UIApplication\) \{{(?P<body>[\s\S]*?)\n    \}}', text)
        if lifecycle_match:
            lifecycle_replacement = lifecycle_match.group(0)
            lifecycle_call = f'irgunDispatchWebLifecycleEvent("{event_name}")'
            if lifecycle_call not in lifecycle_match.group('body'):
                lifecycle_replacement = lifecycle_replacement.replace('{', '{\n        ' + lifecycle_call, 1)
            text = text[:lifecycle_match.start()] + lifecycle_replacement + text[lifecycle_match.end():]
        else:
            additions_lifecycle = f'''
    func {method_name}(_ application: UIApplication) {{
        irgunDispatchWebLifecycleEvent("{event_name}")
    }}
'''
            idx = text.rfind('\n}')
            if idx < 0:
                die('Could not find the end of AppDelegate.swift for lifecycle patch')
            text = text[:idx] + additions_lifecycle + text[idx:]

    # Capacitor's generated AppDelegate already has applicationDidBecomeActive.
    # Add our policy call to that existing lifecycle hook instead of declaring a
    # second method with the same Swift signature.
    active_match = re.search(r'func applicationDidBecomeActive\(_ application: UIApplication\) \{(?P<body>[\s\S]*?)\n    \}', text)
    if not active_match:
        die('Could not find applicationDidBecomeActive in AppDelegate.swift')
    replacement = active_match.group(0)
    if 'irgunApplyWebViewMediaAndZoomPolicy()' not in active_match.group('body'):
        replacement = replacement.replace('{', '{\n        irgunApplyWebViewMediaAndZoomPolicy()', 1)
    if 'irgunScheduleAnalyticsPluginRegistration()' not in replacement:
        replacement = replacement.replace('{', '{\n        irgunScheduleAnalyticsPluginRegistration()', 1)
    text = text[:active_match.start()] + replacement + text[active_match.end():]

    app_delegate.write_text(text)

def write_build_metadata():
    meta = ROOT / 'IOS-CLOUD-BUILD-METADATA.txt'
    meta.write_text(
        f'Bundle ID: {BUNDLE_ID}\nMarketing version: {MARKETING_VERSION}\nBuild number: {BUILD_NUMBER}\n'
        f'Firebase plist installed: {GOOGLE_PLIST.exists()}\n'
        'Capabilities requested: Sign in with Apple, Push Notifications, In-App Purchase, Background Audio\n'
        'Paid digital audio: App Store In-App Purchase / StoreKit 2\n'
    )

def main():
    if not IOS_APP.exists():
        die('No ios/App/App directory. Run: npm run build && npx cap add ios && npx cap sync ios')
    ios_client, reversed_client = decode_firebase_plist()
    patch_info_plist(ios_client, reversed_client)
    write_entitlements()
    write_analytics_plugin()
    patch_app_delegate()
    write_build_metadata()
    print('iOS cloud configuration prepared successfully.')
    print(f'Bundle ID: {BUNDLE_ID}')
    print(f'Google iOS client: {ios_client}')
    print(f'Google callback scheme: {reversed_client}')

if __name__ == '__main__':
    main()
