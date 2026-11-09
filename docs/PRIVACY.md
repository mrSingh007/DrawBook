# DrawBook Privacy Policy

## Notebooks on your device

DrawBook stores notebooks, drawings, typed text, and imported PDF pages in the app’s private storage on your device. The app excludes its notebook directory from automatic device backups. Writing, drawing, and PDF annotation work offline without a DrawBook account. DrawBook uses no analytics, advertising, or tracking.

If you export or share a notebook, PDF, or image, you choose where the copy goes. That destination can retain its own copy. Temporary export files remain in the app’s temporary storage until system cleanup.

## Optional Drawing AI

DrawBook operates no backend and the developer receives and retains no notebook content, AI requests or responses, or provider API keys from the app. If you use Drawing AI, the app sends requests directly over HTTPS to the provider you select, using your API key to authenticate. The provider processes those requests to answer your prompt and suggest edits to the current page. OpenRouter may route the request to a separate model provider.

A request can include your prompt, recent conversation, current-page information, editable objects such as typed text and shapes, and the results of AI page tools. When the model reads the page with its page tools, the request also includes text recognized from your handwriting on your device and simplified stroke coordinates. When **Send Page as Image to AI** is on, the model can request a rendered image of the current page, including your handwriting and sketches and any imported PDF background.

The selected provider and any downstream model provider handle the data under their own terms, privacy policies, and applicable account settings. They may retain content or request metadata. See the provider documentation for retention periods, privacy controls, and deletion options.

- [OpenRouter Privacy Policy](https://openrouter.ai/privacy) and [model-provider logging and retention](https://openrouter.ai/docs/guides/privacy/provider-logging)
- [Ollama Cloud Privacy Policy](https://ollama.com/privacy)
- [Anthropic API data retention](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data)
- [OpenAI API data controls](https://developers.openai.com/api/docs/guides/your-data)

## Your controls and deletion options

- Delete a page or notebook in DrawBook to remove its local copy. Deleting the app removes its local notebooks. Manage copies you exported separately.
- DrawBook keeps chat history in memory. Choose **New thread** to clear it. AI edits saved to the page remain part of the notebook.
- DrawBook stores provider API keys in the device’s Keychain. To remove a key and stop future requests using it, select its provider in **AI configuration**, clear the key, and save. Repeat for each saved key you want to remove. You can also turn off page images to limit what is sent on future requests. Start a new thread to keep earlier conversation text, including descriptions of page images, out of future requests.
- Contact the provider that processed a request to exercise privacy rights or request deletion of data it already received.

## Privacy questions

Contact the project through [DrawBook’s GitHub issue tracker](https://github.com/mrSingh007/DrawBook/issues). Issues are public. For a sensitive question, ask for a private contact route and leave out personal information, notebook content, and API keys.
