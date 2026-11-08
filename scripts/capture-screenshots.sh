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
project = staging / 'DrawBook.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace(
    'PRODUCT_BUNDLE_IDENTIFIER = com.local.papernest',
    'PRODUCT_BUNDLE_IDENTIFIER = com.local.drawbook.screenshots',
))
# Seed the chat preview in the disposable app without saving a key or making a network request.
fixtures = {
    'AISettings.swift': '''
extension AISettings {
    static func screenshotConfiguration() -> AISettings {
        let settings = AISettings()
        settings.provider = .openRouter
        settings.model = AIProvider.openRouter.defaultModel
        settings.imageInput = false
        settings.apiKey = "placeholder-for-screenshots"
        return settings
    }
}
''',
    'DrawingAIChat.swift': '''
extension DrawingAIChat {
    convenience init(screenshotBubbles: [Bubble]) {
        self.init()
        bubbles = screenshotBubbles
    }
}
''',
}
for filename, fixture in fixtures.items():
    with (staging / 'DrawBook' / filename).open('a') as source:
        source.write(fixture)
tests = staging / 'DrawBookTests' / 'NotebookStoreTests.swift'
tests.write_text(tests.read_text() + '\n' + (root / 'scripts/snapshot-fixture.swift').read_text())
PY
result="build/Screenshots-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project build/ScreenshotProject/DrawBook.xcodeproj -scheme DrawBook \
  -destination "$DRAWBOOK_TEST_DESTINATION" -derivedDataPath build/ScreenshotDerivedData \
  -parallel-testing-enabled NO -only-testing:DrawBookTests/DocumentationScreenshots \
  -resultBundlePath "$result" CODE_SIGNING_ALLOWED=NO test
attachments="${result%.xcresult}-attachments"
mkdir -p "$attachments" docs/screenshots
xcrun xcresulttool export attachments --path "$result" --output-path "$attachments"
python3 - "$attachments" <<'PY'
from pathlib import Path
import json, shutil, sys
root = Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
screens = ('library', 'editor', 'drawing-ai')
found = {}
for test in manifest:
    for attachment in test.get('attachments', []):
        name = attachment.get('suggestedHumanReadableName', '')
        for screen in screens:
            if name.startswith((screen + '.', screen + '_')) or name == screen:
                found[screen] = root / attachment['exportedFileName']
assert set(found) == set(screens), 'Screenshot attachments missing; inspect the exported attachment manifest'
for screen in screens:
    shutil.copyfile(found[screen], Path('docs/screenshots') / (screen + '.png'))
print('Saved native UI snapshots in docs/screenshots/')
PY
