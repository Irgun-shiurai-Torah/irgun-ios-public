#!/usr/bin/env bash
set -euo pipefail
test -n "$IRGUN_TEST_EMAIL" && test -n "$IRGUN_TEST_PASSWORD" || { echo "Missing private dedicated QA account secrets"; exit 1; }
node --check .github/regression/observer.js
python3 -m py_compile .github/regression/*.py
npm install --no-audit --no-fund
node --test scripts/test_ios_account_observer.mjs scripts/test_ios_vimeo_modes.mjs scripts/test_ios_playback.cjs
python3 .github/simulator/prepare.py web
# For this disposable test build, use PR #25's richer read-only account observer.
# Do not overwrite production app code or inject the older account XCTest twice.
printf '\n' >> src/main.js
cat .github/regression/account-observer.js >> src/main.js
python3 .github/regression/prepare.py web
npm run build
npx cap add ios
npx cap sync ios
npx @capacitor/assets generate --ios
python3 scripts/prepare_ios_cloud.py
ruby -e "require 'xcodeproj'" 2>/dev/null || gem install xcodeproj --no-document
ruby scripts/patch_xcode_project.rb
python3 .github/simulator/prepare.py native
ruby .github/simulator/configure.rb
python3 .github/account-tests/prepare.py scheme
python3 .github/regression/prepare.py scheme
python3 .github/regression/prepare.py native
bash scripts/assert_no_direct_swiftuicore.sh
if [ -f ios/App/Podfile ]; then
  ( cd ios/App && pod install --repo-update )
fi
