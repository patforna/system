# Android Personal Dictation App — Plan for Review

This document contains the original prompt and Claude's research/proposal.
Intended for handoff to Codex for adversarial review and revision.

---

## Original prompt

Goal: Build a personal Android app that lets me dictate into any input field
by triggering it from the system/keyboard mic icon. Replace what Wispr Flow
does, without the floating overlay. Quality target: match the ChatGPT
mobile app's dictation.

Hard requirements
- No floating overlay or persistent UI. Trigger must be the standard Android
  voice input flow — tapping the mic icon in Gboard/SwiftKey, or the
  RecognizerIntent that other apps fire.
- Languages: primary English, secondary Hochdeutsch. Auto-detect or fast
  toggle, your call — explain the trade-off.
- Backend: OpenAI gpt-4o-transcribe via /v1/audio/transcriptions. API key
  stored in EncryptedSharedPreferences. Wrap the backend behind an
  interface so I can swap to ElevenLabs Scribe v2 later by changing config.
- Push-to-talk: hold mic → record → release → upload → insert text into the
  focused field. Clips are 5–30s, max 60s.
- Personal use only. No telemetry, no analytics, no Play Store. Single APK
  on my own device.

Decisions I want you to research and propose before writing code
1. The right Android integration point. RecognitionService (what
   SpeechRecognizer / RecognizerIntent dispatches to) versus a Voice IME
   with voice subtype. Which one actually gets invoked when I tap the
   Gboard mic? My understanding is Gboard hardcodes Google voice typing —
   confirm and tell me exactly what I need to change (e.g. disable Google
   voice typing in Gboard) to route the mic to my service. If neither path
   is clean, propose the next-best trigger (quick-settings tile,
   accessibility shortcut, assistant action) and the UX trade-off.
2. Audio capture: sample rate, encoding, mono/stereo, container — best
   accuracy-per-byte for gpt-4o-transcribe. Any client-side VAD or silence
   trimming worth doing.
3. Latency budget. Target: under 1.5s end-to-end for a 10s clip. Identify
   where the time goes and what's tunable (chunked upload, keepalive
   connection, etc.).

Deliverables before any implementation
- Architecture sketch (textual fine) of the components: capture, encode,
  upload, transcribe, insert.
- Android permissions and manifest entries.
- Project skeleton: Kotlin, modern Jetpack stack, coroutines, minimal deps.
- Risk list: realistic things that could make this not work — Gboard
  ignoring the system service, OEM modifications, background mic
  restrictions, doze/foreground-service rules.
- MVP cut: smallest thing that proves the integration works end-to-end
  before any polish.

After we agree on the plan, we implement in small steps.

Stack: Kotlin, target API 34+, minimal dependencies, OpenAI's plain HTTP
API (no extra SDK).

Ask before assuming my device model, OS version, or default keyboard.

---

## Claude's proposal

### The Gboard reality

**Tapping Gboard's mic icon cannot be redirected to a third-party service.** Gboard's voice typing is hardcoded to Google's recognizer (on-device or cloud). It does *not* call `SpeechRecognizer` and does not honor the system default `RecognitionService`. Disabling "Voice typing" in Gboard hides the mic icon entirely; it does not fall back to a system voice IME.

Implications:
- A `RecognitionService` implementation only intercepts apps that call `SpeechRecognizer.createSpeechRecognizer()` (some Samsung apps, custom search bars, AOSP-style keyboards). It will *not* affect Gboard, SwiftKey, or most apps' built-in mic buttons.
- The only universal trigger that works inside *any* text field is a **Voice IME** — your app shows up as a keyboard, the user switches to it via the IME switcher (long-press space, or the notification while a keyboard is showing), and your IME runs the PTT flow.

Recommendation: **Voice IME as the primary trigger, plus a `RecognitionService` registration as a freebie for the apps that do honor it.** That gets you "one tap to switch from Gboard to my dictation IME, hold to talk, release inserts text, auto-switch back to Gboard." Two taps total instead of one — but it's the closest thing to universal that Android allows.

If even that's too much friction, the fallbacks are:
- **Quick Settings tile + Accessibility service** — tile to record, Accessibility's `ACTION_SET_TEXT` / `performAction` to insert into the focused field. Works system-wide but Accessibility is intrusive (Android shows a scary warning, OEMs sometimes auto-revoke it).
- **Assistant role** — long-press power/home triggers your app. Insert via Accessibility. Works from lock screen too. Trade-off: replaces Gemini/Assistant.

Start with Voice IME and only add Accessibility if the IME-switch friction bothers you.

### Audio capture

- **16 kHz, mono, PCM 16-bit** at the mic (`AudioRecord`). Matches Whisper-family training; higher rates buy nothing for ASR.
- **Encoding: Opus in OGG**, ~24 kbps mono via `MediaCodec` (hardware-accelerated on every modern device). 10s clip ≈ 30 KB vs ~320 KB for WAV. Encoding runs concurrent with capture, so post-release encode latency is ~0.
- **No client-side VAD.** PTT means the user defines the boundaries; VAD adds latency and bugs. A trivial leading/trailing silence trim (RMS threshold) is fine if we want it later.
- **Container note:** OpenAI accepts `flac, m4a, mp3, mp4, mpeg, mpga, oga, ogg, wav, webm`. OGG/Opus is the sweet spot.

### Latency budget (10s clip, target 1.5s e2e)

| Stage | Realistic | Tunable? |
|---|---|---|
| Stop record + finalize OGG | 30–80 ms | Pre-allocate muxer; encode during capture |
| TLS + HTTP/2 connect | 200–400 ms cold, ~0 warm | **Pre-warm connection on PTT-down** (open TLS to api.openai.com, hold idle) |
| Multipart upload (~30 KB) | 100–300 ms on LTE | Already minimal at Opus sizes |
| `gpt-4o-transcribe` inference | 500–1200 ms | Use `stream=true` to start receiving partial transcripts ~300 ms in; commit final on close |
| `commitText` into IME | <20 ms | — |

**Realistic on a warm connection: 800–1300 ms. 1.5s is achievable but tight on cellular.** Two big wins: pre-warmed connection during recording, and streamed response (start showing text in the field as deltas arrive, finalize on stream end). Note: OpenAI's `/v1/audio/transcriptions` does *not* support streamed uploads — body is one multipart POST. The streaming is on the *response* side only.

### Languages: en + de-DE

Recommend **manual toggle, default to last used**, with a smart default from `EditorInfo.hintLocales` when present. Reasons:
- `language` param materially improves accuracy on short clips.
- Auto-detect on a 5s German utterance often guesses wrong, especially with English code-switching ("Hochdeutsch ist great").
- Toggle UI: long-press the IME's PTT button cycles `en` → `de` → (auto). Tiny, no friction.

Trade-off accepted: one extra long-press on language switch in exchange for reliable accuracy.

### Architecture sketch

```
[ Voice IME (InputMethodService) ]                  ← entry point
        │  PTT down/up events
        ▼
[ DictationController (coroutine scope) ]
        │
        ├──► [ AudioCapture ]  AudioRecord 16k mono ──┐
        │                                             ▼
        │                                      [ OpusOggEncoder ]  MediaCodec
        │                                             │
        ├──► [ ConnectionWarmer ] (TLS pre-warm)      │
        │                                             ▼
        └──► [ Transcriber ] ─── interface ───►  bytes + lang
                  │
                  ├── OpenAITranscriber  (gpt-4o-transcribe, stream=true)
                  └── ElevenLabsTranscriber  (later)
                          │
                          ▼ partial deltas + final
        [ IME.currentInputConnection.commitText ]     ← insertion
        [ InputMethodManager.switchToLastInputMethod ] ← optional auto-return
```

Settings activity: API key (EncryptedSharedPreferences via `MasterKey`), language default, backend selection.

Also register a `RecognitionService` that delegates to the same `Transcriber` — costs almost nothing and helps the apps that honor it.

### Permissions / manifest

- `RECORD_AUDIO` (runtime)
- `INTERNET`
- IME service: `android:permission="android.permission.BIND_INPUT_METHOD"` + `<meta-data ... method.xml>` declaring a voice subtype
- RecognitionService: standard `<intent-filter>` for `android.speech.RecognitionService` plus a `<meta-data android:name="android.speech">` xml. (Note: `BIND_VOICE_RECOGNITION_SERVICE` is not a real permission — needs verification of correct binding string.)
- No `FOREGROUND_SERVICE_MICROPHONE` needed: IME has foreground privileges while visible.
- No `POST_NOTIFICATIONS` unless we surface error toasts via notification (we won't for v1).

### Project skeleton (planned)

```
app/
  build.gradle.kts            // Kotlin, AGP 8+, minSdk 34, targetSdk 34
  src/main/
    AndroidManifest.xml
    kotlin/dev/yourname/dictate/
      ime/VoiceImeService.kt           // InputMethodService
      ime/PttView.kt                   // single fullscreen mic button
      audio/AudioCapture.kt            // AudioRecord wrapper
      audio/OpusOggEncoder.kt          // MediaCodec + Ogg muxer
      net/Transcriber.kt               // interface
      net/OpenAITranscriber.kt         // OkHttp, multipart, SSE response
      net/ConnectionWarmer.kt
      recog/DictationRecognitionService.kt
      settings/ApiKeyStore.kt          // EncryptedSharedPreferences
      settings/SettingsActivity.kt     // Compose, API key + language
    res/xml/method.xml                 // IME subtype
    res/xml/recognition_service.xml
```

Deps (intentionally tiny): `androidx.core`, `androidx.activity-compose`, `androidx.security:security-crypto`, `kotlinx-coroutines`, `okhttp` (for HTTP/2 + multipart + SSE). No Retrofit, no DI framework.

### Risks (realistic)

- **Gboard cannot be redirected** — already covered. Voice IME is the workaround.
- **IME switcher discoverability on first use** — easy to forget how to switch keyboards. Settings screen should show a one-time "how to dictate" card.
- **OEM weirdness** — Samsung/Xiaomi sometimes throttle IME-launched mic access or kill IMEs aggressively. Need to test on the actual device.
- **Auto-switch-back** — `switchToLastInputMethod()` requires the IME token; works in IME context but some launchers / apps reset focus. May need to leave the user in our IME until they manually switch back.
- **`commitText` into specialized fields** — password fields, some banking apps, and rich-text editors (Gmail web, certain WebViews) handle commit oddly. Usually fine; will need empirical testing.
- **Network on cellular** — 1.5s budget is fragile. Pre-warm + Opus give margin; on bad networks we exceed it. Acceptable for v1.
- **OpenAI rate / cost spike protection** — 60s cap is in spec; enforce client-side hard cutoff.
- **EncryptedSharedPreferences deprecation** — the `androidx.security` lib is in maintenance. Still works on API 34, but worth noting; Tink-based replacement may be needed eventually.

### MVP (smallest thing that proves it works)

1. Voice IME with a single fullscreen "hold to talk" button. No keyboard layout.
2. `AudioRecord` → in-memory PCM. **Skip Opus for v1**, upload as WAV.
3. `OpenAITranscriber` with hardcoded `language=en`, no streaming, blocking POST.
4. `commitText` on success.
5. Settings activity with one field: API key.

Ship that, dictate one sentence into Notes, prove the loop. Then add: Opus encoding → streaming response → German toggle → connection pre-warm → optional auto-switch-back → RecognitionService registration.

---

## Open questions Claude flagged before coding

1. **Device + Android version** (Pixel 8 / S24 / etc., Android 14 vs 15)?
2. **Default keyboard** today (Gboard / SwiftKey / other)? Willingness to switch IMEs to dictate, or dealbreaker?
3. **One-tap vs two-tap**: given Gboard's mic is unreachable, OK with the Voice IME flow (switch IME → hold → release → text inserted, optionally auto-switch back), or design around the Accessibility-service approach instead?
4. **Streaming insertion**: partial transcripts appearing as you hold (ChatGPT-style live text), or only the finalized result on release?
5. **Auto-switch-back to Gboard after dictation** — yes/no?

---

## What I want from Codex

Challenge this plan adversarially. Specifically:

- Is the Gboard claim accurate as of late 2025 / early 2026? Any Android 14/15 setting or Gboard flag that *does* let third-party voice routing work?
- Is the Voice IME approach actually the best universal trigger, or is there a cleaner integration point I'm missing (e.g. a system "voice input" role distinct from the IME)?
- Audio format: would FLAC at 16 kHz beat Opus 24 kbps for `gpt-4o-transcribe` accuracy on noisy input? Anything benchmarked publicly?
- Latency budget: are the per-stage estimates realistic, or am I being optimistic about TLS pre-warm benefits with HTTP/2?
- Streaming response on `/v1/audio/transcriptions` for `gpt-4o-transcribe` — is it actually supported, what's the event format, and does it meaningfully reduce time-to-first-token?
- Architecture: anything overbuilt or underbuilt for a single-user APK?
- MVP cut: too small? Too large? What would you ship first?
- Any risks missing from the list?

Push back hard on anything that's wrong or hand-wavy.
