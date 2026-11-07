#!/bin/sh
# Capture native SwiftUI screens in a disposable test project with fictional data.
set -eu
cd "$(dirname "$0")/.."
: "${DRAWBOOK_TEST_DESTINATION:?Set DRAWBOOK_TEST_DESTINATION to an installed iPad simulator}"
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path.cwd()
staging = root / 'build' / 'ScreenshotProject'
if staging.exists():
    shutil.rmtree(staging)
staging.mkdir(parents=True)
for name in ('DrawBook', 'DrawBookTests', 'DrawBook.xcodeproj'):
    shutil.copytree(root / name, staging / name, ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate'))
tests = staging / 'DrawBookTests' / 'NotebookStoreTests.swift'
tests.write_text(tests.read_text() + '\n' + (root / 'scripts/snapshot-fixture.swift').read_text())
PY
result="build/Screenshots-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project build/ScreenshotProject/DrawBook.xcodeproj -scheme DrawBook \
  -destination "$DRAWBOOK_TEST_DESTINATION" -derivedDataPath build/ScreenshotDerivedData \
  -resultBundlePath "$result" CODE_SIGNING_ALLOWED=NO test
attachments="${result%.xcresult}-attachments"
mkdir -p "$attachments" docs/screenshots
xcrun xcresulttool export attachments --path "$result" --output-path "$attachments"
python3 - "$attachments" <<'PY'
from pathlib import Path
import json, shutil, sys
root = Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
found = set()
for test in manifest:
    for attachment in test.get('attachments', []):
        name = attachment.get('suggestedHumanReadableName', '')
        for screen in ('library', 'editor'):
            if name.startswith((screen + '.', screen + '_')) or name == screen:
                shutil.copyfile(root / attachment['exportedFileName'], Path('docs/screenshots') / (screen + '.png'))
                found.add(screen)
assert found == {'library', 'editor'}, 'Screenshot attachments missing; inspect the exported attachment manifest'
print('Saved native UI snapshots in docs/screenshots/')
PY
