# Rewrite

macOS menu-bar app for system-wide grammar correction, text rewriting, and
voice-to-text. The result panel is the primary UI; everything else is plumbing.

## Build and run

```bash
bash Scripts/bootstrap.sh   # one-time per fresh clone — fetches llama.cpp@b9222
bash Scripts/build.sh       # produces build/Rewrite.app + build/Rewrite.dmg
```

Standard rebuild-and-test loop while iterating:

```bash
pkill -x Rewrite; bash Scripts/build.sh \
  && cp -R build/Rewrite.app /Applications/ \
  && open /Applications/Rewrite.app
```

Debug builds run via `swift build` and are useful only for catching compile
errors — the menu-bar app needs the .app bundle (Info.plist, signing,
llama.framework copy) to actually run.

## Architecture (high level)

Source files live in domain-grouped folders under `Sources/Rewrite/`:

- **`App/`** — entry point + glue
  - `GrammarFixerApp.swift` — `@main`
  - `AppDelegate.swift` — global shortcut wiring, mode dispatch, glue between
    STT and LLM. The single point where a shortcut becomes a generation.
  - `HotkeyManager.swift` — Carbon-based global hotkey registration.
  - `AccessibilityService.swift` — reads selected text / writes back via
    `AXUIElement`. Calls `AXIsProcessTrustedWithOptions` for the prompt.
- **`LLM/`** — model providers
  - `LLMService.swift` — provider router. `generate(prompt:)` (one-shot,
    back-compat) and `generateStream(prompt:onChunk:onComplete:)` (current
    primary path). Routes to embedded or remote per `Settings.shared.llmProvider`.
  - `EmbeddedLLMService.swift` — actor wrapping `LocalLLMClient.llama` (Metal
    via llama.cpp). Owns one `LlamaClient` per loaded model; lazy-load + prewarm
    + keep-alive ping; cancellation via `Task.isCancelled`.
  - `Prompts.swift` — rewrite + voice-post-process prompt templates.
- **`Speech/`** — voice / STT pipeline
  - `SpeechService.swift` — Parakeet-only STT facade. WhisperKit was removed;
    do not reintroduce (swift-transformers version conflict with LocalLLMClient).
  - `ParakeetEngine.swift` — sherpa-onnx Parakeet TDT backend.
  - `AudioCapture.swift` — CoreAudio HAL Output mic capture.
  - `AudioLevelMonitor.swift` — RMS level smoothing for the recording UI.
- **`Settings/`** — settings model + windows
  - `Settings.swift` — `ObservableObject` shared store; `UserDefaults`-backed.
  - `SettingsView.swift` — menu-bar popover (mode/model picker).
  - `SettingsWindow.swift` — full Settings window (sidebar tabs).
  - `OnboardingWindow.swift`, `RewriteModesWindow.swift`, `ShortcutRecorder.swift`.
- **`UI/`** — shared chrome / floating panels
  - `FloatingPanel.swift` — non-activating `NSPanel` subclass used by every
    floating window (result, recording indicator).
  - `ResultPanel.swift` + `PopupView.swift` + `PopupState.swift` — the rewrite
    result panel. Becomes key when the first result arrives so Return triggers
    Replace without leaking to the source app. Local `NSEvent` monitor consumes
    keystrokes; global monitor handles Esc during the streaming phase.
  - `RecordingIndicatorPanel.swift` — animated waveform for voice input;
    `Drafting…` / `Cleaning…` shimmer label for post-recording stages.

SwiftPM scans the target directory recursively, so adding subfolders works
without `Package.swift` changes.

## LLM providers

Two providers, switchable in Settings → General:

- **Embedded (default)** — Gemma 4 E2B/E4B Q4_K_M GGUF via llama.cpp/Metal.
  Weights download only when the user clicks "Download Model" — never on
  app launch. Cached under `~/Library/Caches/models/`.
- **Remote** — OpenAI-compatible HTTP endpoint (Ollama / LM Studio). Used
  to be the only path; kept as a fallback.

Both paths stream token-by-token. `generateStream` returns a `StreamHandle`
that should be cancelled when the result panel is dismissed.

## Voice transcript post-processing

After STT finishes, if `Settings.shared.voicePostProcessEnabled` is true,
the transcript is piped through the LLM using `Settings.shared.voicePostProcessPrompt`
(user-editable). Default prompt cleans filler words and fixes punctuation
without paraphrasing.

## Vendored dependencies

`vendor/LocalLLMClient/` — tattn/LocalLLMClient pinned to 0.5.0 with two
local patches we maintain:

1. `Sources/LocalLLMClientLlama/LlamaToolCallParser.swift` — replaced
   `String(std::string)` with `String(cString: __c_strUnsafe())`. Swift 6.2
   C++ interop can't disambiguate the std::string init against the
   LosslessStringConvertible-based one.
2. `Sources/LocalLLMClientLlamaC/common/log.{h,cpp}` — stub additions for
   `LOG_TRC`, `common_log_set_prefix`, `common_log_set_timestamps`,
   `common_fit_params`, `common_memory_breakdown_print`. These are
   referenced by files in `common/` that we do compile, but defined in
   files we cannot compile (they pull in llama.cpp's private `src/` headers).

If you bump the pinned llama.cpp version (`llamaVersion` in
`vendor/LocalLLMClient/Package.swift`), also:
- Update `LLAMA_TAG` in `Scripts/bootstrap.sh`.
- Update the `binaryTarget` URL + sha256 checksum in the same Package.swift.
- Re-sync the symlinks in `Sources/LocalLLMClientLlamaC/common/` (most
  upstream `.h` files in `exclude/llama.cpp/common/` should be symlinked
  in; `.cpp` files only if they don't `#include "../src/..."`).

`vendor/LocalLLMClient/Sources/LocalLLMClientLlamaC/exclude/llama.cpp/` is
gitignored (150 MB). `Scripts/bootstrap.sh` clones it at the matching tag.

`vendor/sherpa-onnx/` — Parakeet runtime. Static libs in this folder are
in Git LFS.

## Known gotchas

- The vendored LocalLLMClient declares MLX-backed targets we don't use,
  which still get resolved (mlx-swift, swift-transformers). They don't get
  linked into our app but they slow resolve. Trimming Package.swift would
  remove them; deferred for now.
- `swift package update` will wipe local patches in `.build/checkouts/`.
  Our patches live in `vendor/LocalLLMClient/` (path-package), so they
  survive — but never edit anything in `.build/checkouts/`.
- macOS Cxx interop is enabled on the Rewrite executable target (required
  by LocalLLMClient's C++ headers). This changed how some Apple framework
  typedefs import (e.g. `AudioUnitRenderActionFlags` → raw `UInt32`).
  `AudioCapture.swift` uses the raw type explicitly to compile under both
  modes.
- Ad-hoc code signing (`codesign --sign -`) invalidates Accessibility
  permissions on every rebuild. The build script prefers the self-signed
  "Rewrite Development" certificate if present.
- macOS Gatekeeper blocks unsigned distributions — users need
  `xattr -cr /Applications/Rewrite.app` once after first install.
- AVAudioEngine conflicts with sherpa-onnx for mic access in the same
  process. Do NOT add AVAudioEngine for audio level monitoring; use the
  existing `AudioCapture` (CoreAudio).
- Modifier-only hotkeys (NSEvent global monitor) must dispatch STT
  start/stop async to avoid deadlock with AudioCapture.

## Commit conventions

Per the user's global rules:
- No `Co-Authored-By` footer on commits or PR descriptions.
- No emoji in code.
- PR title format: `[TICKET_ID] This will <ticket description>`.
