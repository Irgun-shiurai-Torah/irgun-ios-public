#!/usr/bin/env python3
"""Migrate the GENERATED simulator-only iOS project to UIScene for iOS 27.

This runs after the regular Irgun cloud and simulator instrumentation steps
inside an ephemeral GitHub Actions checkout. It does not touch source app code
or the current Xcode 26 production/TestFlight pipeline.
"""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
app = root / "ios/App/App"
info_file = app / "Info.plist"
delegate_file = app / "AppDelegate.swift"
scene_file = app / "SceneDelegate.swift"
template = root / ".github/duo/SceneDelegate.swift"

if not info_file.exists() or not delegate_file.exists():
    raise SystemExit("Create and configure the native iOS project first")
data = plistlib.loads(info_file.read_bytes())
data["UIApplicationSceneManifest"] = {
    "UIApplicationSupportsMultipleScenes": False,
    "UISceneConfigurations": {
        "UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "Default Configuration",
            "UISceneDelegateClassName": "$(PRODUCT_MODULE_NAME).SceneDelegate",
        }]
    },
}
# The scene delegate owns the CAPBridgeViewController/window programmatically.
data.pop("UIMainStoryboardFile", None)
info_file.write_bytes(plistlib.dumps(data, sort_keys=False))

source = delegate_file.read_text()
has_scene_hook = re.search(r"func\s+application\s*\(\s*_\s+application:\s*UIApplication,\s*configurationForConnecting\b", source)
if not has_scene_hook:
    method_code = '''
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
'''
    index = source.rfind("\n}")
    if index < 0:
        raise SystemExit("Could not find AppDelegate class end")
    source = source[:index] + method_code + source[index:]

needed = (
    "irgunConfigurePlaybackAudioSession",
    "irgunInstallAudioSessionObservers",
    "irgunApplyWebViewMediaAndZoomPolicy",
    "irgunScheduleAnalyticsPluginRegistration",
    "irgunDispatchWebLifecycleEvent",
)
for function in needed:
    pattern = rf"private func ({function})\("
    updated, count = re.subn(pattern, rf"func \1(", source, count=1)
    if count != 1:
        raise SystemExit(f"Could not expose {function} to the scene delegate")
    source = updated
delegate_file.write_text(source)
scene_file.write_text(template.read_text())

print("Installed iOS 27 scene manifest, SceneDelegate and native Irgun hooks (simulator only)")
