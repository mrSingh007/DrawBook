#!/bin/sh
# Static checks run without Xcode. --build / --test require full Xcode + iOS SDK.
set -eu
cd "$(dirname "$0")/.."

plutil -lint DrawBook.xcodeproj/project.pbxproj DrawBook/Info.plist DrawBook/PrivacyInfo.xcprivacy
python3 - <<'PY'
import json
import plistlib
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path.cwd()
project = plistlib.loads(subprocess.check_output([
    "plutil", "-convert", "xml1", "-o", "-", "DrawBook.xcodeproj/project.pbxproj"
]))
objects = project["objects"]
missing_ids = []
def visit(value):
    if isinstance(value, dict):
        for nested in value.values():
            visit(nested)
    elif isinstance(value, list):
        for nested in value:
            visit(nested)
    elif isinstance(value, str) and re.fullmatch(r"[A-F0-9]{24}", value):
        if value not in objects:
            missing_ids.append(value)
visit(project)
assert not missing_ids, f"Unresolved Xcode object references: {missing_ids}"

source_paths = []
file_paths = {}
def check_group(group_id, base):
    group = objects[group_id]
    base = base / group.get("path", "")
    for child_id in group.get("children", []):
        child = objects[child_id]
        if child["isa"] == "PBXGroup":
            check_group(child_id, base)
        elif child.get("sourceTree") == "<group>":
            path = base / child["path"]
            assert path.exists(), f"Missing project file: {path}"
            file_paths[child_id] = path
            if path.suffix == ".swift":
                source_paths.append(path)
check_group(objects[project["rootObject"]]["mainGroup"], root)
assert source_paths, "No Swift files in project"

# A file appearing in the navigator is not enough: every Swift file must also
# belong to its app or test target's Sources build phase.
for target in objects.values():
    if target.get("isa") != "PBXNativeTarget":
        continue
    source_folder = root / target["name"]
    if not source_folder.is_dir():
        continue
    built_sources = set()
    for phase_id in target.get("buildPhases", []):
        phase = objects[phase_id]
        if phase.get("isa") != "PBXSourcesBuildPhase":
            continue
        for build_file_id in phase.get("files", []):
            file_ref = objects[build_file_id]["fileRef"]
            path = file_paths.get(file_ref)
            if path is not None and path.suffix == ".swift":
                built_sources.add(path)
    expected_sources = set(source_folder.rglob("*.swift"))
    assert built_sources == expected_sources, (
        f"{target['name']} source membership mismatch: "
        f"missing={expected_sources - built_sources}, extra={built_sources - expected_sources}"
    )

scheme = ET.parse("DrawBook.xcodeproj/xcshareddata/xcschemes/DrawBook.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert ref.attrib["BlueprintIdentifier"] in objects, "Scheme points to an unknown target"
for path in root.glob("DrawBook/Assets.xcassets/**/Contents.json"):
    json.loads(path.read_text())
icon = (root / "DrawBook/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
assert icon[:8] == b"\x89PNG\r\n\x1a\n", "App icon is not PNG"
assert struct.unpack(">II", icon[16:24]) == (1024, 1024), "App icon must be 1024 square"
assert icon[25] == 2, "App icon must be opaque RGB"
subprocess.run(["swiftc", "-frontend", "-parse", *map(str, source_paths)], check=True)
print(f"Project references, scheme, assets, and syntax of {len(source_paths)} Swift files passed.")
print("Syntax validation does not type-check UIKit/SwiftUI or replace an iOS build.")
PY

case "${1:-}" in
    "")
        echo "To compile with Xcode: ./scripts/check-project.sh --build"
        ;;
    --build)
        xcodebuild -project DrawBook.xcodeproj -scheme DrawBook \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
        ;;
    --test)
        : "${DRAWBOOK_TEST_DESTINATION:?Set DRAWBOOK_TEST_DESTINATION, e.g. platform=iOS Simulator,name=iPad (A16)}"
        xcodebuild -project DrawBook.xcodeproj -scheme DrawBook \
            -destination "$DRAWBOOK_TEST_DESTINATION" \
            -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
        ;;
    *)
        echo "Usage: $0 [--build|--test]" >&2
        exit 2
        ;;
esac
