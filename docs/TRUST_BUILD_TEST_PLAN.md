# Trust Build Test Plan

Subs Trust Build v0 proves whether the local Thai/Japanese subtitle loop is
ready to trust in realistic meetings. These tests produce local reliability
reports only. Do not paste sensitive meeting text into issues, logs, or reports.

## Report Location

Each capture session should write:

```text
~/Library/Application Support/Subs/ReliabilityReports/reliability_session_<yyyyMMdd_HHmmss>_<shortSessionID>.json
~/Library/Application Support/Subs/ReliabilityReports/reliability_session_<yyyyMMdd_HHmmss>_<shortSessionID>.md
```

The report must include timings, counters, and local error messages. It must not
include audio, source transcript text, translated subtitle text, or meeting
content.

## Required Scenarios

Run each scenario with `./script/build_and_run.sh --verify` first, then start
capture from the menu bar.

| Scenario | Setup | Expected evidence |
| --- | --- | --- |
| Thai cold start | Quit Subs, relaunch, choose Thai -> English, play realistic Thai meeting audio. | One report with ASR ready, capture running, first audio buffer, first accepted subtitle, translation warmup, and translation latency fields populated where the local models are available. |
| Thai warm start | Stop capture after the cold run, start Thai capture again without quitting. | One new report. Warm start should show shorter ASR/model readiness than cold start if the model stayed warm. |
| Japanese cold start | Quit Subs, relaunch, choose Japanese -> English, play realistic Japanese meeting audio. | One report with the same core fields populated for Japanese. |
| Japanese warm start | Stop capture after the cold run, start Japanese capture again without quitting. | One new report. Warm start should avoid repeated cold model-load behavior where supported. |
| Silence/noisy audio | Start capture with silence, low-volume audio, or non-speech meeting noise. | Report shows first audio buffer and recognition counters such as skipped quiet chunks, low-confidence chunks, candidates, and accepted chunks. The app must not crash or invent repeated accepted subtitles. |
| Permission/model failure recovery | Temporarily remove one local requirement, such as Screen & System Audio permission or a model/runtime folder, then start capture. Restore it and retry. | Failed run produces a report with a clear local failure stage and stop reason. Retry produces a separate report. No cloud fallback is offered or used. |

## Pass/Fail Rubric

A scenario passes when:

- Subs does not crash.
- No meeting audio, transcript text, translation text, or transcript memory is
  stored in the reliability report.
- The app does not send meeting data to any cloud service and does not offer a
  cloud fallback.
- Local setup failures are clear enough for a tester to know which permission,
  runtime, or model is missing.
- First useful accepted subtitle timing is present when speech recognition
  succeeds.
- Candidate, accepted, duplicate, quiet-skip, and low-confidence counters are
  visible in the report.
- Translation warmup and per-translation latency are visible when translation
  runs; translation failures are surfaced locally.

A scenario fails when:

- The app crashes, hangs indefinitely, or silently stops producing reports.
- A report contains audio-derived text or translated meeting content.
- A missing local requirement silently falls back to cloud processing.
- The subtitle stream repeats hallucinated accepted text enough that the tester
  would not use the app in a real meeting.
