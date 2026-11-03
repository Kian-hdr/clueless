# Set up Clueless with a coding agent

Copy the prompt below into your coding agent from the Clueless checkout.

```text
Help me build and set up Clueless on this Mac. Read README.md and AGENTS.md first. Verify that this is an Apple Silicon Mac with macOS 14.2 or newer and Xcode 27 or newer. Run swift test, then ./script/build_and_run.sh --build-only. Report any exact build or toolchain problem.

Check that the Codex CLI is installed at /opt/homebrew/bin/codex and can run. If sign-in is needed, point me to the normal CLI sign-in flow. Do not read or print auth files or credentials.

Tell me how to create an ElevenLabs key with speech-to-text access and enter it directly in Clueless Settings → Setup → Save to Keychain. Never ask me to paste the key into this chat, a command, or a repository file. The optional direct OpenAI Fast opening can wait. Use Codex answers if the protected helper is not configured.

Launch Clueless after the build. Start with capture paused. Guide me through the macOS audio prompts when I choose to listen. Use synthetic text for a first answer check. Leave personal memory and launch notetaking settings for me to choose. If I request MCP setup, register the local stdio bridge from this checkout and verify its read-only status command.
```
