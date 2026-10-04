#!/usr/bin/env python3
"""Inject diagnostics into the disposable simulator checkout, never release builds."""
import argparse
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def web():
    source = ROOT / 'src/main.js'
    text = source.read_text()
    if 'window.ISTSimulator =' in text:
        raise SystemExit('Simulator bridge already injected; use a fresh checkout')
    bridge = (HERE / 'bridge.js').read_text().replace(
        '__SIMULATOR_VIDEO_ID__', json.dumps(os.environ.get('SIMULATOR_VIDEO_ID', '')))
    source.write_text(text + '\n' + bridge)


def native():
    app = ROOT / 'ios/App/App'
    source = app / 'AppDelegate.swift'
    text = source.read_text()
    signature = 'func applicationDidBecomeActive(_ application: UIApplication) {'
    if text.count(signature) != 1:
        raise SystemExit('Expected exactly one applicationDidBecomeActive hook')
    text = text.replace(signature, signature + '''
        #if targetEnvironment(simulator)
        SimulatorProbe.shared.install(in: window)
        #endif
''', 1)
    source.write_text(text)
    shutil.copyfile(HERE / 'SimulatorProbe.swift', app / 'SimulatorProbe.swift')
    tests = ROOT / 'ios/App/SimulatorUITests'
    tests.mkdir(exist_ok=True)
    shutil.copyfile(HERE / 'PlaybackUITests.swift', tests / 'PlaybackUITests.swift')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['web', 'native'])
    args = parser.parse_args()
    globals()[args.stage]()
