// Static regression checks for the iOS reader-only paid audio experience.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const main = readFileSync(new URL('../src/main.js', import.meta.url), 'utf8');
const pkg = readFileSync(new URL('../package.json', import.meta.url), 'utf8');
const xcode = readFileSync(new URL('../scripts/patch_xcode_project.rb', import.meta.url), 'utf8');
const cloud = readFileSync(new URL('../scripts/prepare_ios_cloud.py', import.meta.url), 'utf8');
const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
for (const text of ['NativePurchases', 'IOS_IAP_PRODUCT_BY_PAID_AUDIO', 'purchasePaidAudioIos',
 'restoreIosPaidPurchases', 'data-ios-restore-purchases', '/apple-iap/confirm']) {
 assert.equal(main.includes(text), false, 'Unexpected IAP code: ' + text);
}
assert.equal(pkg.includes('@capgo/native-purchases'), false);
assert.equal(xcode.includes("system_caps['com.apple.InAppPurchase'] ="), false);
assert.equal(cloud.includes('StoreKit 2'), false);
assert.equal(html.includes('js.stripe.com'), false, 'Do not load Stripe on iOS');
assert.match(main, /function ensureWebStripeSdk\(\) \{\s*if \(IS_IOS\) return Promise.reject/);
assert.match(main, /state\.paidCatalog = fetchedItems/);
assert.equal(main.includes('data-ios-donation-web="sponsor"'), false);
assert.match(main, /Charitable donations support free Torah lectures\. Donating does not unlock paid audio/);
assert.match(main, /function paidShiurimHtml\(\) \{\s*if \(IS_IOS\)/);
assert.match(main, /const owned = state\.paidCatalog\.filter\(item => item\.owned\)/);
assert.match(main, /const available = state\.paidCatalog\.filter\(item => !item\.owned\)/);
assert.match(main, /Browse additional lecture collections/);
assert.match(main, /function paidCheckoutModalHtml\(\) \{\s*if \(IS_IOS\) return ''/);
assert.doesNotMatch(main, /if \(IS_IOS && !item\?\.owned\) return ''/);
assert.match(main, /paid-card-preview/);
assert.match(main, /View Details/);
assert.match(main, /async function initPaidCheckout\(productId\) \{[^]*?if \(IS_IOS\) return;/);
assert.match(main, /apiJson\('\/paid-audio\/play-session'/);
assert.match(main, /apiJson\('\/paid-audio\/create-session'/);
console.log('iOS reader-only static checks passed');
