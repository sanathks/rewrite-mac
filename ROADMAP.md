# Rewrite — Roadmap

Tracked features picked from research on 2026-05-20. Order is build order:
least risky → biggest UX impact. Each item ships as its own commit so any
can be reverted in isolation.

Legend: `[ ]` not started · `[~]` in progress · `[x]` done

---

## 1. Custom vocabulary for voice — `~30 min` · low risk

`[x]` shipped 2026-05-20 · commit `29fbd02`

Bias Parakeet's recogniser toward user-supplied terms so names and
acronyms transcribe correctly the first time.

- New setting: `voiceHotwords: [String]` (newline-separated in UI,
  JSON-encoded in UserDefaults).
- `ParakeetEngine`: feed list into sherpa-onnx's hotwords config when
  starting recognition.
- Settings → Voice tab gets a TextEditor.

Validation: bad/empty lines silently ignored; sherpa-onnx tolerates them.

---

## 2. Services menu integration — `~1.5 h` · low risk

`[ ]`

Right-click selected text in any app → Services → Rewrite → mode.
Native macOS extension point; no extra runtime cost.

- `Info.plist`: `NSServices` entry per mode (Fix Grammar, Clarity, …).
- `AppDelegate`: `NSApp.servicesProvider = self`; `@objc rewriteService`
  receives the `NSPasteboard`, runs the corresponding mode through the
  existing `runMode` pipeline.
- Setting: `showInServicesMenu: Bool` (default true) — master switch.

Caveat: Services menu sometimes needs `pbs -flush` to pick up new
registrations on first install; document this.

---

## 3. Glossary / always-replace rules — `~2 h` · low risk

`[ ]`

Apply user-defined regex/literal substitutions to LLM output **before**
insertion. Lock spellings, strip em-dashes, normalise brand terms.

```swift
struct GlossaryRule: Codable, Identifiable, Equatable {
    var id: UUID
    var pattern: String          // plain text or regex
    var replacement: String
    var isRegex: Bool            // default false
    var caseSensitive: Bool      // default false
    var wholeWord: Bool          // default true when not regex
    var enabled: Bool            // per-rule toggle
}
```

- New module `Sources/Rewrite/Glossary/GlossaryProcessor.swift` — pure
  `apply(_ text: String) -> String`.
- `AppDelegate.runMode`: pipe LLM output through `GlossaryProcessor`
  before `AccessibilityService.replaceTextInSourceApp`.
- New `Settings/GlossarySettingsTab.swift` — list with add / edit /
  remove / reorder / per-rule enable.

Configurable:

- Master `glossaryEnabled: Bool`.
- Per-rule `enabled`.
- Drag-reorder (later rules see earlier rule output).

Bad regex caught with `try? NSRegularExpression`; rule is marked invalid
in the UI instead of crashing.

---

## 4. Rewrite history — `~3 h` · low–medium risk

`[ ]`

Persist last N rewrites locally. Browse from the menu-bar dropdown.

```swift
struct RewriteHistoryEntry: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var modeName: String
    var originalText: String
    var rewrittenText: String
    var modelLabel: String?
}
```

- New `Sources/Rewrite/History/HistoryStore.swift` — actor; persists
  JSON to `~/Library/Application Support/Rewrite/history.json`; enforces
  cap; prunes by retention. Writes debounced 500 ms.
- `AppDelegate`: append on every successful rewrite.
- Menu-bar dropdown gains a `Recent Rewrites` submenu (timestamp + mode +
  preview; click = copy, ⌘-click = reinsert).
- New `Settings/HistorySettingsTab.swift`.

Configurable (Settings → History):

- `historyEnabled: Bool` (default true).
- `historyMaxEntries: Int` (default 50, slider 10–500).
- `historyRetentionDays: Int` (default 30; 0 = forever).
- "Clear history…" button (confirmation prompt).
- *deferred*: per-app exclusion list (don't record from 1Password, etc.).

Privacy: stored locally only, never sent anywhere. Note this prominently
in the History tab description.

---

## 5. Follow-up edits in the result panel — `~2 h` · medium risk

`[ ]`

After a rewrite lands, a `Refine…` text field appears in the result
panel. Type *"shorter"* or *"more formal"*, Return, the model
regenerates using the previous output as context. Repeatable.

```
┌────────────────────────────────────────┐
│ Fix Grammar  To English  Clarity       │
├────────────────────────────────────────┤
│ <rewritten text>                       │
├────────────────────────────────────────┤
│ ↻ Refine: [ ___________________ ] ↩    │
├────────────────────────────────────────┤
│ [ ↩ Replace ]   ↺  📋  ✕               │
│ gemma-4-E4B · 42 tok/s                 │
└────────────────────────────────────────┘
```

- `PopupState`: new `onRefine: ((String) -> Void)?`.
- `PopupView`: TextField below the result, only in `.result` phase
  (disabled while streaming).
- `ResultPanel`: wire `onRefine`.
- `AppDelegate`: handle refine by building a follow-up prompt
  (`previousOutput + "\n\nRefine: \(instruction)…"`) and re-streaming
  into the same panel via `appendChunk`.

Edge cases:

- Empty input ignored.
- Refines stack — each operates on the latest output, not the original.
- `Replace` always uses the latest text, not the chain.
- Local keyboard monitor for the panel must coexist with the TextField's
  own first-responder.

Risk: keyboard focus interactions can be fiddly with the existing
non-activating panel.

---

## 6. Final-result diff highlighting — `~2 h` · low–medium risk

`[ ]` (decide whether to ship)

For grammar/clarity modes, render the **final** result (not the streaming
intermediate) as word-level diff against the original. Green additions,
struck-through grey deletions. Apple Writing Tools style.

- `Sources/Rewrite/UI/Diff.swift` — pure-Swift LCS-based word diff (~100
  lines, no dependency).
- `PopupView`: render `.result` text as `AttributedString` when the
  current mode opts in.
- `RewriteMode.showDiff: Bool` — default `true` for grammar/clarity,
  `false` for tone/translate (their outputs are intentionally different).

Skipping the live-streaming variant: the LCS would have to recompute on
every chunk and the result would flicker. Final-only is the useful
behaviour anyway — users read the final output.

If `showDiff: false` for the current mode → falls back to plain Text
(current behaviour).

---

## Build order summary

| # | Feature                | Effort  | Risk      |
| - | ---------------------- | ------- | --------- |
| 1 | Voice hotwords         | 30 min  | low       |
| 2 | Services menu          | 1.5 h   | low       |
| 3 | Glossary               | 2 h     | low       |
| 4 | History                | 3 h     | low–med   |
| 5 | Follow-up edits        | 2 h     | medium    |
| 6 | Diff highlighting      | 2 h     | low–med   |

Total: ~11 h. Each item commits independently.

---

## Out of scope (intentionally)

- **Chat mode** — LM Studio / Ollama webui already cover it; would
  dilute the menu-bar tool's focus.
- **Cloud sync of settings** — single-machine power-user tool.
- **Themes** — dark only is on-brand.
- **Usage analytics** — vanity metric.
- **Skhd config writer** — discussed; deferred until we hit a user who
  needs it. Carbon hotkeys + conflict warnings work today.
