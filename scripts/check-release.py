#!/usr/bin/env python3
"""Audit public source; optionally create an audited, allowlisted source ZIP.

This is a release guard, not a guarantee that every secret is detectable. It does
not inspect Git history, ignored build products, or the user's notebook data.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


TOP_LEVEL = {
    "README.md", "LICENSE", "LICENSE.md", "CONTRIBUTING.md", "SECURITY.md",
    "CHANGELOG.md", "CODE_OF_CONDUCT.md", ".gitignore", ".gitattributes",
}
SKIP_DIRS = {"build", "DerivedData", "xcuserdata", ".git", "__pycache__", ".DS_Store"}
TEXT_SUFFIXES = {".swift", ".plist", ".xcprivacy", ".json", ".pbxproj", ".xcscheme",
                 ".xcworkspacedata", ".xcsettings", ".sh", ".py", ".md", ".yml", ".yaml"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".svg"}
SECRET_SUFFIXES = {".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".provisionprofile",
                   ".keystore", ".jks", ".ipa", ".xcarchive", ".xcuserstate"}
PATTERNS = {
    "private-key material": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    "service token": re.compile(r"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{15,}|AIza[A-Za-z0-9_-]{30,})\b"),
    "embedded URL credentials": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
    "absolute user path": re.compile(r"(?:/Users/|/home/)[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\"),
    "personal signing team": re.compile(r'\bDEVELOPMENT_TEAM\s*=\s*([^;\n]+);'),
    "credential assignment": re.compile(
        r'''(?i)\b(?:api[_-]?key|password|client[_-]?secret|access[_-]?token|auth[_-]?token)\b\s*[:=]\s*["'](?!\$|YOUR_|your_|example|placeholder|changeme|test|dummy|<)[A-Za-z0-9_+/=.-]{12,}["']'''),
}


def sensitive_name(path: Path) -> bool:
    name = path.name.lower()
    return (path.suffix.lower() in SECRET_SUFFIXES or name == ".env" or name.startswith(".env.")
            or name in {"id_rsa", "id_ed25519", "credentials", "credentials.json", "secrets.json",
                        "secrets.yml", "secrets.yaml", ".netrc", ".npmrc"})


def audit(root: Path) -> tuple[list[Path], list[str]]:
    """Return relative files eligible for publication and redacted findings."""
    files: list[Path] = []
    findings: list[str] = []
    projects = sorted(root.glob("*.xcodeproj"))
    if not projects:
        findings.append("Missing Xcode project.")
    if not (root / "README.md").is_file():
        findings.append("Missing README.md.")
    if not any((root / name).is_file() for name in ("LICENSE", "LICENSE.md")):
        findings.append("Missing public license.")

    roots = set(projects)
    for project in projects:
        roots.update(root / name for name in (project.stem, project.stem + "Tests", project.stem + "UITests"))
    roots.update(root / name for name in ("scripts", "docs", ".github/workflows"))

    def inspect(path: Path, is_top: bool = False) -> None:
        relative = path.relative_to(root)
        if path.is_symlink():
            findings.append(f"{relative}: symbolic links are not allowed in public source.")
            return
        if sensitive_name(path):
            findings.append(f"{relative}: private/generated file is not allowed in public source.")
            return
        if path.is_dir():
            if path.name not in SKIP_DIRS:
                for child in sorted(path.iterdir()):
                    inspect(child)
            return
        if not path.is_file() or path.name in SKIP_DIRS:
            return
        if not is_top and path.suffix.lower() not in TEXT_SUFFIXES | IMAGE_SUFFIXES:
            findings.append(f"{relative}: file type is not on the release allowlist.")
            return
        # Also examine ASCII text embedded in image metadata, without displaying it.
        content = path.read_bytes().decode("utf-8", errors="ignore")
        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(content):
                if label == "personal signing team" and match.group(1).strip() in {'""', "''"}:
                    continue
                line = content.count("\n", 0, match.start()) + 1
                findings.append(f"{relative}:{line}: {label} (value redacted).")
        files.append(relative)

    # Root-level credential files must not silently disappear behind the allowlist.
    for path in sorted(root.iterdir()):
        if sensitive_name(path) or path.name in TOP_LEVEL:
            inspect(path, is_top=True)
    for path in sorted(roots):
        if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
            findings.append(f"{path.relative_to(root)}: a parent directory is a symbolic link.")
            continue
        if path.exists() or path.is_symlink():
            inspect(path)
    return sorted(set(files)), findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--package", action="store_true", help="Create an audited source ZIP under build/release.")
    args = parser.parse_args()
    root = args.root.resolve()
    files, findings = audit(root)
    if findings:
        print("Release audit failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1
    print(f"Release audit passed: {len(files)} allowlisted source files; no configured sensitive patterns found.")
    print("Excluded: build products, user Xcode state, and Git metadata/history.")
    if not args.package:
        return 0
    destination = root / "build" / "release"
    # A symlinked build directory must never redirect release writes elsewhere.
    if (root / "build").is_symlink() or destination.is_symlink():
        print("Release output directory must not be a symbolic link.", file=sys.stderr)
        return 1
    destination.mkdir(parents=True, exist_ok=True)
    name = sorted(root.glob("*.xcodeproj"))[0].stem
    output = destination / f"{name}-source.zip"
    if output.is_symlink():
        print("Release archive must not be a symbolic link.", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix=".source-", dir=destination) as temp:
        staged = Path(temp) / name
        staged.mkdir()
        for relative in files:
            target = staged / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / relative, target, follow_symlinks=False)
        staged_files, staged_findings = audit(staged)
        if staged_findings or staged_files != files:
            print("Staged source audit failed; no archive was created.", file=sys.stderr)
            for finding in staged_findings:
                print(f"- {finding}", file=sys.stderr)
            return 1
        temporary_zip = Path(temp) / "source.zip"
        with zipfile.ZipFile(temporary_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for relative in staged_files:
                archive.write(staged / relative, arcname=str(Path(name) / relative))
        temporary_zip.replace(output)
    print(f"Created build/release/{output.name} ({output.stat().st_size:,} bytes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
