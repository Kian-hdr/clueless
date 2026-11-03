# First run

1. Download `Clueless-0.3.0-arm64.dmg` from the [GitHub release](https://github.com/Kian-hdr/clueless/releases/tag/v0.3.0). Open the image, drag **Clueless** to **Applications**, then open it from there. Look for the outline speech bubble in the menu bar.
2. In [ElevenLabs API Keys](https://elevenlabs.io/app/developers/api-keys), create a key with **Speech to Text** access. In Clueless, open the sliders button → **Setup**, enter the key in the secure field, and click **Save to Keychain**. Use your own key. Keep it out of chat and source files.
3. For live answers, [install the Codex CLI](https://learn.chatgpt.com/docs/codex/cli) and run `codex login` in Terminal. Clueless looks for `/opt/homebrew/bin/codex`. Confirm that file is executable. Clueless uses your signed-in Codex session. A separate OpenAI API key is optional for the direct Fast opening.
4. Try **Question → Try sample question** to check answer generation without recording audio. For live transcription, choose **Start listening** and follow the macOS microphone and system audio permission prompts. Choose **Pause listening** to stop capture.

For notes only, use **Start as notetaker on launch** from the Clueless menu bar. It is off by default. When enabled, launch starts transcription without live answers, and pause or normal quit saves finalized Markdown locally. Clueless sends audio to ElevenLabs while listening. Answer generation uses OpenAI. Provider usage and retention terms apply.
