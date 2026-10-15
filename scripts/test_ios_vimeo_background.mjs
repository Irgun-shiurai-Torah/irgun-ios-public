import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const main=readFileSync(new URL('../src/main.js',import.meta.url),'utf8');
const native=readFileSync(new URL('./IrgunUnifiedPlayerPlugin.swift',import.meta.url),'utf8');
test('Vimeo-only shiur uses existing native Worker MP4 resolver',()=>{assert.match(main,/\/download\/\$\{encodeURIComponent\(vimeoId\)\}\?type=vimeo/);assert.match(main,/await openNative\(vimeoUrl\)/);});
test('Home preserves background audio and avoids automatic PiP',()=>{assert.match(native,/audiovisualBackgroundPlaybackPolicy\s*=\s*\.continuesIfPossible/);assert.match(native,/canStartPictureInPictureAutomaticallyFromInline\s*=\s*false/);assert.match(native,/guard isPiPRequested else/);assert.match(native,/tapPiP\(\)[\s\S]*?isPiPRequested\s*=\s*true/);});
