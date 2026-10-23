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
    language = os.environ.get('SIMULATOR_LANGUAGE', 'en').strip().lower()
    if language not in {'en', 'he'}:
        raise SystemExit('SIMULATOR_LANGUAGE must be en or he')
    bridge_source = (HERE / 'bridge.js').read_text()
    if bridge_source.count('__SIMULATOR_VIDEO_ID__') != 1:
        raise SystemExit('Expected exactly one simulator video ID placeholder')
    if bridge_source.count('__SIMULATOR_LANGUAGE__') != 1:
        raise SystemExit('Expected exactly one simulator language placeholder')
    if bridge_source.count('__SIMULATOR_DUO_POSE__') != 1:
        raise SystemExit('Expected exactly one Duo pose placeholder')
    pose = os.environ.get('DUO_POSE', '').strip().lower()
    if pose not in {'', 'folded', 'unfolded'}:
        raise SystemExit('DUO_POSE must be empty, folded, or unfolded')
    bridge = bridge_source.replace(
        '__SIMULATOR_VIDEO_ID__', json.dumps(os.environ.get('SIMULATOR_VIDEO_ID', ''))
    ).replace('__SIMULATOR_LANGUAGE__', json.dumps(language)).replace(
        '__SIMULATOR_DUO_POSE__', json.dumps(pose)
    )
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
