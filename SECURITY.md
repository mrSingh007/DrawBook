# Security and privacy

DrawBook has no server, user account, API key, analytics, advertising, or automatic network transfers. The app stores notebooks in its sandbox, with atomic writes and iOS file protection. It excludes notebooks from automatic device backup; users must export editable backups themselves.

Imports are treated as untrusted. The app checks file locality/type, size limits, notebook versions and identifiers, relative background filenames, drawing integrity, and shape values. Editable backup export refuses unreadable drawings or PDF backgrounds. These checks do not make arbitrary PDFs or backups inherently trustworthy.

## Reporting a vulnerability

Do not post credentials, private notebook contents, signed builds, or exploitable personal data in public issues. If the public repository enables GitHub private vulnerability reporting, use its **Security → Report a vulnerability** flow. If that option is unavailable, open an issue asking for a private reporting channel without including exploit details or private data. There is no dedicated security mailbox or response-time guarantee at present.

## Publishing source

Run `python3 scripts/check-release.py` and `./scripts/package-source.sh`. The archive includes only allowlisted source and documentation. It excludes build products, Xcode user state, and Git metadata. The scanner reports pattern categories and file locations without echoing matched values. It is a safeguard, not a complete secret detector.

This working directory had no Git history during the initial review. If you publish an existing repository, scan its full history separately. If an actual credential is ever committed, revoke/rotate it; deleting the current copy does not remove historical exposure.
