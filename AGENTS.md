# Working on Clueless

Clueless is a SwiftPM macOS app for Apple Silicon. It uses SwiftUI for the views and AppKit for the floating, nonactivating panel. Build with Xcode 27 or newer and target macOS 14.2 or newer.

- `Sources/InterviewCore` owns the audio capture, ElevenLabs WebSocket, transcript models, and isolated answer transports.
- `Sources/InterviewAssistant` owns the app lifecycle, panel, workspace, local settings, and meeting notes.
- `Sources/CluelessFastAnswer` is the optional protected OpenAI Responses helper.
- `script/clueless_mcp.py` is a local stdio bridge. Live controls use a Unix socket inside a user-private directory. Saved transcript tools only read files from the local notes directory.
- `Resources/Clueless.icon` is the editable Icon Composer artwork. `script/build_icon.sh` compiles it into the bundle.

Run `swift test` and `./script/build_and_run.sh --build-only` after a change. Run the app explicitly when visual verification is needed. To regenerate the synthetic screenshots, run `CLUELESS_PREVIEW_PATH="$PWD/docs/images" swift test --filter testRenderSyntheticPreviewWhenRequested`.

Keep mic and system audio separate. Keep the floating panel nonactivating. Stream readable text as it arrives. Preserve a complete visible opening if a later stage fails. Keep capture, saved notes, and automatic launch recording opt-in. Do not add implicit screen capture or execution of model-generated code.

Use synthetic transcript and profile fixtures in tests and screenshots. Never read, print, commit, or copy API keys, Codex auth files, private Vault contents, live transcripts, or raw audio. Ask users to enter keys directly into Setup. Run live provider checks only when needed and authorized. A local screenshot is not evidence of receiving-side screen-share privacy.
