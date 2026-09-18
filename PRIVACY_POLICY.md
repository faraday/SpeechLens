# SpeechLens Privacy Policy

**Last Updated:** August 3, 2026 · **Effective Date:** August 3, 2026

SpeechLens processes media on your Mac. With independent consent, it sends
sanitized native crashes, release-health sessions, daily activity, and
successful enhancement-performance records to Sentry. The detailed diagnostic
snapshot remains local.

---

## 1. Core Commitment: 100% On-Device Processing

- **No Audio Uploads:** All speech enhancement, MLX model inference, and audio processing occur 100% locally on your Apple Silicon Mac. Your audio files, voice recordings, and media containers are **never** uploaded to any server.
- **No File Path Tracking:** Absolute local filesystem paths (e.g. `/Users/username/Private/Audio.wav`) are never recorded or transmitted.

---

## 2. Privacy & Diagnostics Preferences

SpeechLens exposes two controls in the top-level **Privacy & Diagnostics**
section of the main menu:

- **Send crash reports and basic diagnostics** is enabled by default.
- **Help improve enhancement performance** is enabled by default.

No reporting starts from the default-on first-run presentation. SpeechLens does
not initialize Sentry or transmit until the user accepts onboarding and enables
at least one reporting capability.

The first control stores separate permissions for native crash reporting and
basic diagnostics. The interface changes both permissions together, but runtime
code enforces them independently. Basic diagnostics include one daily active
installation record.
Enhancement-performance permission is independent, on by default, and controls
only the performance records described below. Its records carry the same
consent-epoch installation identifier while any telemetry remains enabled.

### A. Crash Reports and Basic Diagnostics

When crash reporting is enabled, SpeechLens uses Sentry to capture unhandled
native exceptions and signals. A pending native crash is normally sent after
the next launch. Crash events contain:

- native exception or signal type, thread stacks, loaded debug images, and
  symbolication identifiers;
- SpeechLens release and build;
- macOS version and coarse hardware, CPU, GPU, core-count, and memory facts; and
- when an operation is active, its kind, stable phase, model version/selection,
  and processing profile, chunk, and overlap settings.

SpeechLens does not send audio, media contents, filenames, paths, transcripts,
raw handled errors, arbitrary logs, arbitrary media metadata, screenshots, view
hierarchies, breadcrumbs, attachments, session replays, or profiles. Reports
carry a random installation identifier as Sentry `user.id`; it is not derived
from hardware or an account. It is deleted when all telemetry is disabled and a
new value is generated if reporting is later enabled.

With basic diagnostics enabled, SpeechLens sends at most one activity record per
UTC day on launch or meaningful use. That record contains only app version and
build, macOS version, coarse hardware model, and the telemetry sample rate.
The local diagnostic snapshot is not sent.

With crash reporting enabled, Sentry automatic sessions provide crash-free
release-health statistics. Sessions are not SpeechLens's DAU/MAU source.

### B. Enhancement Performance

When this independent control is enabled, SpeechLens submits one record after
every eligible, successfully committed, user-requested enhancement. Records
contain App and Processing wall/phase timings, real-time factor, audio duration,
audio sample rate and channel count, coarse container and codec classes,
processing profile/chunk/overlap, model and app release/build, build
configuration, telemetry environment, macOS version, and coarse hardware,
CPU/GPU/core-count/memory facts.

Failed, cancelled, stale, model-download, playback, seeking, and waveform-only
operations do not send performance records. Audio, filenames, paths, URLs,
stream indices, transcripts, raw errors, arbitrary media metadata, and custom
operation identifiers are excluded. The Sentry transaction's own near-zero
duration is only a transport-container artifact; SpeechLens uses the explicit
timing measurements for analysis.

---

## 3. Local Diagnostic Snapshot

The current diagnostic snapshot is stored locally at:

`~/Library/Application Support/SpeechLens/Diagnostics/latest-operation.json`

It is replaced as new operations are recorded. No server receives this file,
and it is never attached to a crash event.

The local snapshot may contain app/OS/hardware facts, operation and stable phase,
stable failure/notice codes, model/settings, coarse media/container facts,
output-plan facts, and processing duration. It excludes audio, filenames, paths,
raw error descriptions, and arbitrary logs.

## 4. Data Processor, Location, and Retention

Sentry is SpeechLens's processor for crash, session, activity, and
performance data. The Sentry organization stores event data in the European
Union region in Frankfurt, Germany. Accepted data is retained for 30 days.

SpeechLens keeps at most five pending Sentry envelopes in a dedicated local
cache. Sentry Cocoa removes cached envelopes after at most 90 days. The Sentry
organization is configured not to retain source IP addresses and to scrub
derived geographic user data. Server-side scrubbing supplements, but does not
replace, the app's client-side allowlist.

---

## 5. How to Change Your Preferences

You can modify or revoke your telemetry preferences at any time:

1. **Via App UI:** Open SpeechLens and expand the top-level **Privacy &
   Diagnostics** section in the main menu. Toggle **Send crash reports and basic
   diagnostics** or **Help improve enhancement performance**.
2. **Via macOS Terminal:** Run the following command to reset all preferences:
   ```bash
   defaults delete dev.speechlens.SpeechLens
   ```

Changing either telemetry capability stops the current SDK client, invalidates
its transport, purges the retired capability-mode cache, and starts a fresh
cache for any remaining capability. This privacy-first restart can discard
queued events for a capability that remains enabled. Turning both controls off
purges every telemetry cache and deletes the local installation identifier and
daily-activity marker. Re-enabling creates a new identifier and does not upload
historical local diagnostic snapshots or retired-mode events. Events already
accepted by Sentry are not selectively deleted and expire under the 30-day
retention period. The identifier is not linked to a SpeechLens account or a
known person.

---

## 6. Contact & Inquiries

If you have any questions regarding this privacy policy or data handling practices, please open an issue on our GitHub repository or contact the maintainers.
