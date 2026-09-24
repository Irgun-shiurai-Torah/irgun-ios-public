import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    // iPadOS 15 uses the Safari 15 WebKit engine. Vite 8 defaults to
    // Safari/iOS 16.4+, so the app must be transpiled lower explicitly.
    target: ['safari15'],
    cssTarget: ['safari15'],
  },
});
