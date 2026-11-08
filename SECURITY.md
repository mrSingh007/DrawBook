# Security and privacy

DrawBook has no backend, analytics, advertising, or automatic network transfers. The app stores notebooks in its sandbox, with atomic writes and iOS file protection. It excludes notebooks from automatic device backup; users must export editable backups themselves.

Optional Drawing AI uses a user-provided key for OpenRouter, Ollama Cloud, Claude (Anthropic), or OpenAI. Each key is stored separately in the device’s Keychain. Sending a chat prompt sends it, conversation history, and editable page objects, including typed text, to the selected provider. When **Include handwriting and sketches** is on, the request also includes simplified coordinates and request-scoped IDs for freehand strokes. This setting lets AI remove shared strokes and clear ink. When **Send Page as Image to AI** is on for the selected provider, the agent can request a JPEG rendering of the current page, which includes the paper, any imported PDF page, typed text and shapes, and shared ink only when ink sharing is on. Otherwise, PencilKit files and PDF backgrounds stay local. DrawBook validates the returned edits against the captured page before applying them through the canvas’s undo history.

Imports are treated as untrusted. The app checks file locality/type, size limits, notebook versions and identifiers, relative background filenames, drawing integrity, and shape values. Editable backup export refuses unreadable drawings or PDF backgrounds. These checks do not make arbitrary PDFs or backups inherently trustworthy.

## Reporting a vulnerability

Do not post credentials, private notebook contents, signed builds, or exploitable personal data in public issues. If the public repository enables GitHub private vulnerability reporting, use its **Security → Report a vulnerability** flow. If that option is unavailable, open an issue asking for a private reporting channel without including exploit details or private data. There is no dedicated security mailbox or response-time guarantee at present.

## Publishing source

Run `python3 scripts/check-release.py` and `./scripts/package-source.sh`. The archive includes only allowlisted source and documentation. It excludes build products, Xcode user state, and Git metadata. The scanner reports pattern categories and file locations without echoing matched values. It is a safeguard, not a complete secret detector.

This working directory had no Git history during the initial review. If you publish an existing repository, scan its full history separately. If an actual credential is ever committed, revoke/rotate it; deleting the current copy does not remove historical exposure.
