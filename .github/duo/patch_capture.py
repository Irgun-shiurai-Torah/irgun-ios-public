#!/usr/bin/env python3
# Duo screenshots are captured from XCUIScreen.screens, never inactive XCUIScreen.main.
"""Use the active iPhone Duo display for *real* XCTest screenshots.

XCUIScreen.main is always the cover display. On an unfolded Duo that screen
can be powered off, making 26 identical black images while the UI test passes.
Inject this change into the generated test target ONLY for the Duo workflow.
"""
import os
from pathlib import Path

pose = os.environ.get("DUO_POSE")
if pose not in ("folded", "unfolded"):
    raise SystemExit(f"Unknown DUO_POSE: {pose!r}")
w, h = {"folded": (1398, 2034), "unfolded": (2853, 2007)}[pose]
source_file = Path("ios/App/SimulatorUITests/PlaybackUITests.swift")
source = source_file.read_text()
target = "    func testZZAppStoreScreenshotsOfAllPublicPages() throws {"
if source.count(target) != 1:
    raise SystemExit("Could not find exactly one App Store screenshot test")
old_capture = "let screenshot=XCTAttachment(screenshot:XCUIScreen.main.screenshot())"
if source.count(old_capture) != 1:
    raise SystemExit("Could not find exactly one store screenshot capture call")

helper = r"""
    private func duoStoreScreenshot() throws -> XCUIScreenshot {
        let expectedWidth = __WIDTH__
        let expectedHeight = __HEIGHT__
        var inspected: [String] = []

        func bigEndian32(_ bytes: [UInt8], _ offset: Int) -> Int {
            (Int(bytes[offset]) << 24)
              | (Int(bytes[offset + 1]) << 16)
              | (Int(bytes[offset + 2]) << 8)
              | Int(bytes[offset + 3])
        }

        // Never use XCUIScreen.main for unfolded screenshots: it selects the
        // physical cover panel, which is black when the hinge is fully open.
        // Ask XCTest for its available screen surfaces and select by raw
        // native PNG pixels. Require landscape pixels for the unfolded pose;
        // portrait screenshots are rejected instead of rotated after capture.
        for screen in XCUIScreen.screens {
            let capture = screen.screenshot()
            let bytes = [UInt8](capture.pngRepresentation.prefix(24))
            guard bytes.count == 24, Array(bytes.prefix(8)) ==
                [137, 80, 78, 71, 13, 10, 26, 10] else {
                inspected.append("non-PNG")
                continue
            }
            let width = bigEndian32(bytes, 16)
            let height = bigEndian32(bytes, 20)
            inspected.append("\(width)x\(height)")
            let matches = abs(width - expectedWidth) <= 2 &&
                          abs(height - expectedHeight) <= 2
            if matches {
                print("DUO_CAPTURE: using native \(width)x\(height) pixels")
                return capture
            }
        }
        let reason = "Duo panel \(expectedWidth)x\(expectedHeight) not found in XCUIScreen.screens: \(inspected)"
        XCTFail(reason)
        throw Failure.timedOut(reason)
    }

""".replace("__WIDTH__", str(w)).replace("__HEIGHT__", str(h))

source = source.replace(target, helper + target, 1)
source = source.replace(old_capture, "let screenshot=XCTAttachment(screenshot:try duoStoreScreenshot())", 1)
source_file.write_text(source)
print(f"Patched disposable XCUITest screenshot capture to use {pose} display {w}x{h}")
