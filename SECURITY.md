# Security and privacy

DrawBook has no backend, analytics, advertising, or automatic network transfers. The app stores notebooks in its sandbox, with atomic writes and iOS file protection. It excludes notebooks from automatic device backup; users must export editable backups themselves.

Optional Drawing AI uses a user-provided key for OpenRouter, Ollama Cloud, Claude (Anthropic), or OpenAI. Each key is stored separately in the device’s Keychain. **Activate** in **AI configuration** opens a dialog that names the provider, explains what it can access, and asks users to check the provider’s privacy and data security under their plan. Provider charges may apply. **OK** saves and enables Drawing AI for the selected provider, model, and page image setting. **Cancel** closes the form without saving. A different configuration requires activation. **Deactivate** withdraws permission for the active configuration and keeps the key. **Remove Saved API Key** deletes the selected provider’s stored key.

Sending a chat prompt shares the prompt, recent conversation, and a summary of the current page with the selected provider. When the AI reads the page with `get_page_state`, the tool result includes editable page objects such as typed text and shapes, handwriting recognized on the device, and stroke data. The default result includes simplified coordinates for sketch strokes. The AI can request coordinates for all strokes, including recognized handwriting. When **Send Page as Image to AI** is on for the selected provider, the AI can also use `view_page` to request a JPEG rendering of the current page, including the paper, any imported PDF background, typed text, shapes, and ink. Original PencilKit and PDF files stay on the device. The provider’s data handling and retention policies apply. DrawBook validates the returned edits against the captured page before applying them through the canvas’s undo history.

Imports are treated as untrusted. The app checks file locality/type, size limits, notebook versions and identifiers, relative background filenames, drawing integrity, and shape values. Editable backup export refuses unreadable drawings or PDF backgrounds. These checks do not make arbitrary PDFs or backups inherently trustworthy.

## Reporting a vulnerability

Do not post credentials, private notebook contents, signed builds, or exploitable personal data in public issues. If the public repository enables GitHub private vulnerability reporting, use its **Security → Report a vulnerability** flow. If that option is unavailable, open an issue asking for a private reporting channel without including exploit details or private data. There is no dedicated security mailbox or response-time guarantee at present.

## Publishing source

Run `python3 scripts/check-release.py` and `./scripts/package-source.sh`. The archive includes only allowlisted source and documentation. It excludes build products, Xcode user state, and Git metadata. The scanner reports pattern categories and file locations without echoing matched values. It is a safeguard, not a complete secret detector.

This working directory had no Git history during the initial review. If you publish an existing repository, scan its full history separately. If an actual credential is ever committed, revoke/rotate it; deleting the current copy does not remove historical exposure.
