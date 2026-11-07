# Release verification

Reviewed on 7 November 2026 using Xcode 27.2.

## Source and privacy review

- Reviewed application source, project settings, tests, assets, and documentation.
- Removed the preconfigured Apple development team from both app build configurations.
- Moved local Xcode user state out of the source project; it is excluded from public packaging.
- Replaced personal device/setup notes and historical development logs with public installation instructions.
- No passwords, API tokens, or private-key material were found in the reviewed source. The app contains no network client or third-party dependencies.
- Added a repeatable source scanner and an allowlisted, staged source ZIP builder. Generated builds, signing artifacts, logs, personal notebooks, and Xcode user state are excluded.
- There was no `.git` directory in the reviewed workspace, so no commit history was available to audit.

## Fixes

- Import now rejects remote URLs and nonregular files before document parsing.
- Backup export refuses corrupt PDF backgrounds instead of producing an unrestorable backup.
- Regression coverage verifies path-traversal rejection without changing existing notebooks.
- Deferred teardown of an old drawing canvas no longer clears a newly attached page's shape selection.
- The library heading and create button adapt to narrow windows, and the PDF filter has a relevant empty state.

## Executed checks

- Project references, target membership, plists, shared scheme, icon assets, and Swift syntax: passed.
- Unsigned generic iOS simulator builds of the renamed DrawBook project, Debug and Release configurations: passed.
- All 51 XCTest regression cases: passed on the iPad (A16), iOS 27.2 simulator. The suite also passed after renaming the project, alongside one additional documentation screenshot test (52 total).
- Native SwiftUI screenshots: captured using the real library and editor views with an isolated temporary notebook store and fictional content. No personal notebooks are used.

The screenshots are native view snapshots, not App Store screenshots or photographs of a physical device. Reproduce them with:

```sh
DRAWBOOK_TEST_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/capture-screenshots.sh
```

This creates a disposable project under `build/`, runs the tests, exports XCTest image attachments, and copies the two selected images into `docs/screenshots/`.

## Remaining hardware checks

Before distributing a signed release, check on a physical iPad:

1. Stylus alignment, pressure/tilt where supported, palm rejection, and fast erasing.
2. Drawing, zooming, two-finger page turns, undo/redo, and background/resume with saved notes intact.
3. PDF import, PNG/PDF export, and editable backup/restore through Files.
4. Reinstalling over an existing installation with its original signing team and Bundle Identifier.
5. Compact layouts and larger accessibility text sizes on the devices you intend to support.

No physical-device installation or App Store submission was performed in this review. Passing tests does not imply the absence of all bugs. The selected name, DrawBook, is intentionally not claimed to be unique or trademark-cleared.
