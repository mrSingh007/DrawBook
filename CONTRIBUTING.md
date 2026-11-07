# Contributing to DrawBook

Open `DrawBook.xcodeproj` with Xcode 26 or later. The app has no external packages or backend setup.

Keep changes focused and describe the user-visible behavior. For a bug fix, include reproduction steps and a regression test when it protects meaningful behavior. Run `./scripts/check-project.sh --build` and the XCTest suite on an installed iOS simulator. Include real-device results when changing stylus input, palm rejection, or gesture performance.

Preserve existing notebook and backup compatibility. Do not change storage paths, bundle identifiers, or backup type identifiers without a migration plan. Never silently replace unreadable drawings or discard failed saves.

Do not commit developer teams, provisioning profiles, credentials, personal notebooks, Xcode user state, derived data, or logs containing personal paths. Run `python3 scripts/check-release.py` before contributing. Use fictional content in screenshots and test fixtures.

Contributions are distributed under this project's MIT license. Only submit code and assets you have the right to contribute under that license.
