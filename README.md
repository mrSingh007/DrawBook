# DrawBook

**A quiet place to write, sketch, and think.**

DrawBook is a free, open-source notebook for iPad and iPhone. Write with a compatible stylus, sketch with native brushes, annotate PDFs, and keep your notebooks on your device. Built with SwiftUI, PencilKit, and PDFKit.

**MIT licensed · Works offline · No account · No ads · No subscriptions · No third-party dependencies**

## Screenshots

Native iPad simulator view snapshots with fictional sample notebooks.
![DrawBook notebook library](docs/screenshots/library.png)
![DrawBook drawing workspace](docs/screenshots/editor.png)

## What you can do

- Organize notebooks with five cover colors, title search, recent sorting, rename, and duplication.
- Write on blank, ruled, grid, or dotted paper, with multiple pages per notebook.
- Use ballpoint, monoline, highlighter, fountain pen, pencil, watercolor, and crayon brushes. Reed pen is available on iPadOS 26 or later.
- Adjust each pen's color and width; erase with a variable-size rubber; use lasso and ruler.
- Add editable rectangles, ellipses, triangles, lines, and arrows. Move, resize, rotate, fill, duplicate, and partially erase shapes.
- Point with a temporary red laser that disappears after three seconds and never enters saved notes or exports.
- Undo and redo on the current page, pinch to zoom, and pan with two fingers. Pull beyond a page edge to turn pages.
- Import PDFs, export a page as PNG or a notebook as PDF, and export/restore editable backups.
- Save automatically, with visible save errors and retry controls.

## Get started

### Requirements

- A Mac with **Xcode 26 or later** and the iOS platform installed. Use a version that supports your device's OS. This project uses the iOS 26 PencilKit SDK while supporting devices running **iOS/iPadOS 17 or later**.
- An iPad or iPhone, or an installed iOS simulator.
- For installation on a physical device, your own Apple signing team and a unique Bundle Identifier. No Apple Account is needed for simulator builds.

### Build and run

1. Open **`DrawBook.xcodeproj`** in Xcode. No package installation or project generation is required.
2. Choose the **DrawBook** scheme and an iPad simulator, then press **⌘R**.
3. For a real device, select the **DrawBook target → Signing & Capabilities**, choose your own team, and set a unique Bundle Identifier such as `com.yourname.drawbook`.
4. Connect and trust your device, enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), choose it as the run destination, and press **⌘R**.

A free Apple Account can be used for personal device testing; free provisioning expires and requires periodic rebuilding. See [Apple's current membership and Personal Team limitations](https://developer.apple.com/help/account/membership/compare-memberships). The source code is free; Apple's signing and distribution requirements are separate.

**Updating an existing installation:** keep its original team and Bundle Identifier, and install over the app. Export editable backups first. The default `com.local.papernest` identifier, private `PaperNest` storage directory, and `.papernest` backup format are intentionally retained from earlier development builds so a display-name change does not strand existing notebooks. New users should choose their own Bundle Identifier.

### Your first notebook

1. Choose **New notebook**, give it a title, and select a cover and paper style.
2. Write with a stylus recognized by iPadOS. For a mouse, finger, or touch-based stylus, enable **Touch drawing** in the page menu.
3. Choose a pen, then tap the color circle or size control to adjust it.
4. Use **Show pages** for page thumbnails and the page menu to add pages or change paper.
5. Use **Share → Editable notebook backup** regularly to protect your work.

Pressure, tilt, buttons, and palm rejection depend on your hardware. Touch drawing provides less palm rejection than Pencil mode.

## Backups, exports, and privacy

| Format | Use | Editable ink and shapes? |
| --- | --- | --- |
| `.papernest` | Complete notebook backup and restore | Yes |
| PDF | Share the entire notebook | No; ink is flattened |
| PNG | Share the current page at 1536 × 2048 | No |

Use **Import PDF or backup** in the library to restore a backup. Restoration creates a separate notebook and leaves the original unchanged. PDFs must be unlocked and no larger than 200 pages / 250 MB. Editable backups have a 500 MB limit.

Notebooks stay in the app's private local storage. There is no networking, login, backend, telemetry, advertising, or automatic cloud sync. Files use atomic writes and iOS file protection. Corrupt ink is preserved rather than silently overwritten. Sharing happens only through the destination you select in the system share sheet.

**Keep your own backups.** The notebook directory is excluded from automatic device/iCloud backup. Deleting the app, losing the device, or changing signing identity can make notebooks unavailable. Save important editable backups to Files, an external drive, or another destination you trust. Share exports temporarily remain in the app's sandbox until system cleanup.

## Development and verification

```sh
# Validate project references, assets, plists, and Swift syntax.
./scripts/check-project.sh

# Compile an unsigned iOS simulator build.
./scripts/check-project.sh --build

# Run XCTest on an installed simulator (choose one from -showdestinations).
xcodebuild -project DrawBook.xcodeproj -scheme DrawBook -showdestinations
DRAWBOOK_TEST_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/check-project.sh --test

# Scan only the intended public source, with redacted findings.
python3 scripts/check-release.py

# Create a staged, rescanned source archive in build/release/.
./scripts/package-source.sh
```

If Xcode is not selected, prefix a command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Build output stays in ignored `build/` directories. See [the verification report](docs/VERIFICATION.md) for the checks actually completed and remaining hardware checks.

The XCTest suite covers persistence, failed-write recovery, malformed imports, corruption checks, backups, PDF backgrounds, shape editing, erasure, undo/redo, page navigation, laser expiry, and export rendering. Passing tests reduce risk; they do not establish that every device and workflow is bug-free.

### Known limits

- This is a source distribution, not an App Store download or a signed installable IPA.
- Pages use a fixed 768 × 1024 document canvas. Imported PDFs keep their proportions, with margins where needed.
- Undo history lasts while a page is open. PNG and PDF exports cannot restore editable ink.
- No text/OCR search, cloud sync, audio recording, collaboration, or handwriting recognition.
- Physical stylus accuracy, palm rejection, and fast erasing require testing on your own iPad.

## Project map

| Location | Purpose |
| --- | --- |
| `DrawBook/LibraryView.swift` | Library, creation, imports, and help |
| `DrawBook/NotebookEditor.swift` | Page navigation, saving, and sharing |
| `DrawBook/DrawingCanvas.swift` | PencilKit input, erasing, zoom, and undo |
| `DrawBook/ToolControls.swift` | Drawing tools and style controls |
| `DrawBook/NotebookStore.swift` | Local persistence, validation, backup/restore |
| `DrawBook/PageRenderer.swift` | Paper, PDF backgrounds, and exports |
| `DrawBook/ShapeRenderer.swift` | Editable shape geometry and rendering |
| `DrawBookTests/` | XCTest regression coverage |
| `scripts/` | Build checks and safe source packaging |

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance and [SECURITY.md](SECURITY.md) for privacy and reporting guidance. Publish the source archive produced by the packaging script; do not upload the entire working folder, which can contain personal Xcode state and signed build products.

## License and name

[MIT License](LICENSE). Free to use, modify, share, and use commercially, subject to retaining the copyright and license notice. Provided without warranty. Apple's frameworks and tools remain subject to Apple's terms.

DrawBook is the chosen project name; **it is not claimed to be unique or reserved**. This project is independent of other similarly named products. No trademark clearance or App Store name reservation is implied.
