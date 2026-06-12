# Competitive Product Review: On-Device Realtime Translation

Last reviewed: 2026-06-12

## Product Thesis

Subs should become the best local-only Mac subtitle bar for Thai/Japanese
meetings where the user needs English understanding without sending meeting
audio, transcripts, translations, diagnostics, or memory to a cloud service.

The product should not try to beat broad cloud meeting suites on language count,
voice cloning, summaries, or admin workflows yet. It can beat them on a sharper
promise:

```text
Open any meeting app
  -> check local readiness before the call
  -> press Start
  -> get readable English subtitles on the Mac
  -> keep meeting data on the device
```

## Market Scan

Apple Live Captions proves the baseline expectation for a native desktop caption
experience: captions work across apps, run on device, can stay onscreen, can
switch between computer audio and microphone audio, and can be resized,
positioned, and styled. Apple also clearly warns about language availability and
accuracy limits.

Windows Live Captions has the same key pattern at OS level: system-wide captions,
offline use, personalization, and, on Copilot+ PCs, translation into English.
The important product lesson is not OS breadth; it is that users expect captions
to follow them across whatever app is currently playing audio.

Zoom, Teams, DeepL Voice, Wordly, and Krisp show demand for meeting translation,
but most of that market is cloud, platform, or enterprise workflow centric. Their
useful patterns are language-pair selection, meeting-app integration, multiple
output modes, attendee choice, and explicit paid readiness/admin setup. Their
architecture is not a fit for Subs when it requires cloud processing of meeting
data.

Seagull and Sokuji are closer to the independent desktop wedge. Seagull's
visible promise is simple: capture any computer audio and show translated
subtitles in a floating overlay. Sokuji shows that users value local inference,
desktop and browser reach, simple and advanced modes, model downloads, virtual
microphone routing, subtitles, and speech-to-speech. Subs should copy the clarity
and setup affordances, not the cloud-provider surface area.

## What To Copy And Adapt

1. App-agnostic capture

   Keep ScreenCaptureKit system-audio capture as a core differentiator. The user
   should not need a Zoom, Teams, Meet, or browser extension integration to get
   value.

2. Pre-call readiness

   Copy the setup confidence pattern from enterprise tools and OS-level caption
   settings: the user should know before the meeting whether capture permission,
   speech model, translation runtime, selected language-pair model, local-only
   mode, and recent reliability evidence are ready.

3. Caption bar first

   Copy Apple/Windows' minimal caption-surface bias. The live overlay should be
   a subtitle bar, not a dashboard. It needs readable text, stable placement,
   a compact local-only signal, capture activity, and blocking errors only when
   action is required.

4. Clear language-pair ownership

   Copy Zoom's language-pair framing, but keep it narrow: Thai -> English and
   Japanese -> English until real meeting evidence supports expansion.

5. Evidence-driven trust

   Copy the enterprise expectation that reliability can be checked and reported,
   but keep reports local and no-text. Use timings, counters, backend names, and
   local error stages only.

6. Simple/advanced split

   Copy Sokuji's simple-vs-advanced shape. Default surfaces should stay calm;
   diagnostics, evals, model/runtime details, and reliability reports belong in
   Settings or separate windows.

## What Not To Copy

- Do not add cloud ASR, cloud translation, cloud summaries, cloud logging, or
  silent network fallback.
- Do not chase dozens of languages before Thai/Japanese quality is trustworthy.
- Do not make speech-to-speech, voice cloning, accent conversion, or meeting
  bots part of the next milestone.
- Do not put transcripts, summaries, diarization, or diagnostics in the default
  live subtitle surface.
- Do not make setup clever at the cost of privacy. Missing local models should
  stop that stage and explain the local fix.

## Senior Product Plan

### Positioning

Subs should be positioned as:

> Private realtime English subtitles for Thai and Japanese meetings, processed
> on your Mac.

The product should be deliberately narrower and more trustworthy than generic
translation suites. The first product win is a user joining a real Thai or
Japanese meeting, pressing Start, and getting useful English subtitles without
setup ambiguity, repeated hallucinations, or unacceptable delay.

### Milestone 1: Trust Build

Goal: make one real meeting flow feel dependable.

- Add and use pre-call readiness checks.
- Run the trust-build call matrix against realistic Teams/system-audio sessions.
- Fix the highest-impact failures found in local reports and manual notes.
- Track cold start, warm start, first audio, first candidate, first accepted
  subtitle, first translated subtitle, duplicate rate, quiet-skip rate,
  translation latency, and crash/failure stages.
- Keep all reports local and content-free.

### Milestone 2: Thai/Japanese Quality

Goal: prove language quality before widening scope.

- Expand text translation evals for decisions, owners, dates, deadlines, risks,
  interruptions, accents, noisy ASR-shaped fragments, and meeting-app phrases.
- Add ASR pipeline evals with public, non-sensitive Thai/Japanese samples.
- Compare OPUS-MT, M2M100 bakeoff, and any future local runtime by latency,
  memory, package size, and meeting usefulness.

### Milestone 3: Daily Overlay

Goal: make the subtitle surface feel like a polished product.

- Make the overlay stay where users put it.
- Support always-on-top behavior and a path toward click-through where macOS
  allows it.
- Add restrained caption appearance controls: size, width, opacity, and source
  text visibility.
- Keep debug metrics out of the overlay.

### Milestone 4: Setup And Distribution

Goal: make first-run local setup boring.

- Show model/runtime status in plain language.
- Provide local model install/repair affordances from Settings.
- Support bundled or preinstalled enterprise model folders.
- Never download models during live meeting processing.

### Deferred

- Persistent transcript storage.
- Diarization.
- Summaries and action items.
- Voice-to-voice or virtual microphone output.
- More languages.

These become candidates only after live subtitles are trustworthy in real
meetings.

## Plan Review

This plan deliberately favors trust over breadth. That is the right tradeoff for
Subs because competitors already own broad cloud language catalogs, while the
local-only Thai/Japanese meeting niche is underserved.

The main risk is that local translation quality is not good enough with OPUS-MT.
The mitigation is not to broaden product scope; it is to make evals realistic,
measure latency, and bake off local candidates behind the existing translation
backend contract.

The second risk is startup friction. A private local stack is less magical than
cloud APIs unless readiness is obvious before the meeting. That is why pre-call
readiness moves into the reliability sprint instead of remaining a later polish
task.

## Executed Now

- Added a local `Check Readiness` action in the app menu and Settings.
- Added a shared readiness summary so the menu bar shows whether the selected
  local language pair is ready, checking, unchecked, or needs action.
- Updated the canonical build order to fold pre-call readiness into the trust
  sprint.

## Sources

- Apple Live Captions:
  https://support.apple.com/guide/mac-help/get-captions-of-spoken-and-computer-audio-mchldd11f4fd/mac
- Windows Live Captions:
  https://support.microsoft.com/en-us/accessibility/windows/use-live-captions-to-better-understand-audio
- Zoom translated captions:
  https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0059081
- DeepL Voice for Meetings:
  https://www.deepl.com/en/products/voice/deepl-voice-for-meetings
- Wordly Zoom Translation:
  https://www.wordly.ai/zoom-translation
- Krisp AI Voice Translation:
  https://help.krisp.ai/hc/en-us/articles/18597976598556-Krisp-AI-Voice-Translation
- Seagull Product Hunt listing:
  https://www.producthunt.com/products/seagull-subtitles-for-everything
- Sokuji GitHub repo:
  https://github.com/kizuna-ai-lab/sokuji
