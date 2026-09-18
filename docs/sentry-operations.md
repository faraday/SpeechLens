# Sentry Operations

This guide explains how maintainers configure, audit, test, and use Sentry for
SpeechLens. The [Telemetry Contract](telemetry.md) defines what the app may
send. A Sentry setting, dashboard, or workflow must not collect anything beyond
that contract.

## Audited client baseline

SpeechLens currently pins Sentry Cocoa 9.24.0 in Xcode's resolved Swift package
file. Sentry is compiled directly into the App executable and is not a runtime
dependency of any other target. Xcode may still copy an unused
`Sentry.framework` directory into the build. `Tools/prepare-app-runtime.sh`
verifies that the executable does not depend on that framework and removes the
unused copy. Packaging fails if it remains.

Because the framework's bundled privacy manifest is removed with it,
SpeechLens keeps the reviewed Apple required-reason API declarations in
`Sources/App/Resources/PrivacyInfo.xcprivacy`.

The release workflows pin Sentry CLI 3.6.2 and verify its version before use.
Do not update either version as part of an unrelated dependency refresh.

### SDK upgrade audit

For every Sentry Cocoa upgrade:

1. Read the SDK release notes and inspect the source code that defines the
   default value of every option used by
   `Sources/App/SentryCrashReporter.swift`. Look for newly enabled automatic
   features, changes to crash caching or shutdown uploads, new session fields,
   user/device identifiers, and changes to the serialized payload.
2. Compare those defaults with every feature SpeechLens disables in the
   telemetry contract. Explicitly turn off any new automatic collector before
   changing the pinned version.
3. Re-run the `SpeechLensAppTests` that exercise the pre-send boundary. They
   must still cover exact transaction names, exact measurement and label sets,
   unsafe input strings, all consent combinations, cache changes, revocation,
   and relaunch without a consent change.
4. Build the app and confirm Sentry remains statically linked, the copied
   wrapper is removed, and no unexpected non-system dynamic dependency ships.
5. Compare Sentry's declarations for Apple's required-reason APIs with
   SpeechLens's privacy manifest. Update the app-owned manifest only after
   confirming why each API is used and that its declared reason applies.
6. Run the signed QA inspections below for crashes, sessions, activity, and
   performance. Inspect raw payloads rather than relying on the issue UI.
7. Reconcile `PRIVACY_POLICY.md`, App Store Connect privacy answers,
   onboarding/settings copy, and `docs/telemetry.md`. Record the SDK version,
   reviewer, QA event links, and audit date in the release checklist.

Even if an SDK feature is off by default today, SpeechLens should keep its
explicit setting where the API permits it. The final pre-send field check also
remains mandatory.

## Organization and project settings

Before allowing a QA or production project to receive data, verify:

1. The organization is in the EU data region in Frankfurt. The client rejects
   non-Frankfurt project upload addresses (DSNs), and the release CLI targets
   `de.sentry.io`.
2. Error, transaction, and session retention used by SpeechLens is 30 days.
3. Multi-factor authentication is required. Keep one organization owner for
   billing/security administration and give maintainers only the project/team
   permissions needed for triage.
4. Source-IP storage is disabled.
5. Server-side data scrubbing is enabled, including an advanced rule removing
   `$user.geo.**`.
6. No server-side feature infers or retains additional user identity.
7. The project has enough event and transaction quota for the release. Review
   alerts and external integrations to ensure they do not copy telemetry to an
   unapproved destination.

These server settings are a backup layer in case a client-side safeguard fails;
they do not replace the app's pre-send checks. Save evidence of the initial
configuration. Review it before publication and whenever the organization,
plan, or Sentry policy changes.

## Build configuration and credentials

`SENTRY_DSN` contains the Sentry project upload address. It identifies the
destination but does not grant administrative access. SpeechLens still injects
it only while building the app; an empty value disables Sentry.
`SpeechLensSentryEnvironment` is `development` for Debug and `production` for
Release; signed QA builds may override it with `qa`.

The protected GitHub `release` environment supplies:

- `SENTRY_DSN`;
- `SENTRY_AUTH_TOKEN`, restricted to the debug-file/release permissions needed
  by the release script;
- `SENTRY_ORG`; and
- `SENTRY_PROJECT`.

Never commit or embed the auth token. The release name recorded by the app and
the release created in Sentry must both be
`dev.speechlens.SpeechLens@<marketing-version>+<build>`. A mismatch prevents
reliable symbolication and release grouping.

## Release and symbolication

Symbolication turns crash memory addresses into readable function names and
source locations. It requires the debug-symbol file (dSYM) produced by the
exact app archive that crashed.

`Tools/release.sh` archives the app, requires
`SpeechLens.app.dSYM`, creates the matching Sentry release if necessary,
uploads the archive dSYMs with `sentry-cli debug-files upload --wait`, and
finalizes the release before export and notarization. Missing credentials,
missing dSYMs, upload failure, or release-script failure blocks publication.

For signed crash QA:

1. Build a signed Release-configuration app with environment `qa`, a QA DSN,
   and a unique version/build. Upload the matching archive dSYM.
2. Accept onboarding, enable reliability reporting, and launch outside the
   debugger.
3. Trigger an approved deliberate unhandled native crash. A locally captured
   handled exception is not a substitute because the client filter requires
   `handled == false`.
4. Relaunch once so Sentry can upload the queued crash payload.
5. Open that exact event. Verify its release, build number (Sentry calls this
   the distribution), environment, loaded-code metadata, and readable
   SpeechLens function names. Confirm the dSYM UUID shown by Sentry matches the
   archive.
6. Record the event link, release/build, archive identity, reviewer, and date.

If stack frames still show memory addresses instead of function names, compare
the event's loaded-code UUIDs with the archived dSYM. Then confirm the event's
release name exactly matches the release created by `Tools/release.sh`.
Receiving the crash is not enough; unreadable frames fail this check.

## Raw payload QA

Use Sentry's raw JSON view or an equivalent QA capture that shows the payload
as it was serialized for sending. Inspect every top-level field and nested
context because Sentry's normal issue and transaction pages hide some fields.
Use a QA project and test media with no private content. Store the audit
evidence where only authorized maintainers can access it.

### Crash, session, and revocation

- Confirm the crash is an unhandled native event and contains only the native
  crash material plus the two fixed-field SpeechLens contexts from the
  telemetry contract.
- Confirm `user.id` is a UUID and that email, username, IP address, geography,
  SDK installation identifiers, paths, filenames, URLs, raw messages/errors,
  breadcrumbs, logs, requests, attachments, source context, and frame variables
  are absent.
- Confirm crash consent enables release-health sessions. With only basic or
  performance consent enabled, confirm the crash handler and automatic
  sessions are off.
- Disable crash consent, repeat the crash, relaunch, and confirm that no crash
  request or queued payload from the old permission combination remains.
- Queue a QA crash, revoke and re-enable rapidly, then confirm the old crash is
  not uploaded and its queued payload file is not recreated.
- Disable all telemetry and confirm every permission-combination cache, the
  consent-epoch UUID, and the daily marker are deleted. Re-enable and confirm
  the new UUID differs.

### Daily activity

- Enable basic diagnostics and verify exactly one
  `app_daily_active / speechlens.activity` transaction per UUID per UTC day,
  even when the app checks repeatedly during that day.
- Confirm it has no measurements or child spans and exactly the six dimensions
  documented in the telemetry contract.
- Confirm the UUID appears only as `user.id`. The payload must not contain an
  operation outcome, local diagnostic data, hardware detail beyond
  `hardware_model`, or app/device/language contexts automatically added by the
  SDK.

### Enhancement performance

- Enable only performance reporting. Confirm there is no native crash handler,
  automatic session, or automatic transaction.
- Complete one enhancement and verify one
  `media_enhancement / speechlens.enhancement` top-level transaction with no
  child spans. Its ten measurements and dimension keys must match the
  telemetry contract exactly.
- Confirm the transaction identifiers are valid and `user.id` is a UUID.
  Paths, filenames, URLs, stream indices, operation IDs, raw errors, request
  data, SDK-added app/device/language contexts, stack data, and loaded-code
  metadata must be absent.
- Verify failed, cancelled, stale, model-download, playback, seeking, and
  waveform-only work emits nothing.
- Revoke performance consent during active work. The local enhancement may
  complete normally, but no performance transaction may upload.

## Dashboards and saved queries

Use a 30-day dashboard range unless a release comparison needs a smaller
period. DAU means daily active installs; MAU means active installs over the
rolling 30-day window.

### Reliability

- DAU: `count_unique(user.id)` filtered to
  `span.op:speechlens.activity`, shown in one-day buckets.
- Rolling MAU: a single-value `count_unique(user.id)` over the same activity
  operation and 30-day range.
- Crash-free sessions: Sentry Release Health only. Do not use automatic session
  counts as SpeechLens DAU or MAU.
- Crash triage: top unhandled native issues by release/build, with
  readable SpeechLens frames, macOS version, coarse hardware, and the fixed
  active-operation fields.

Treat active-install counts as estimates, not exact totals. Events may be lost
offline, dropped when the project exceeds quota, or affected by sampling.
Sentry may also approximate counts when there are many distinct identifiers.

### Performance

Save views for the median (p50) and the 90th and 95th percentiles (p90/p95) of:

- `real_time_factor` and `avg_channel_real_time_factor`;
- `processing_total_seconds`, `enhancement_pass_seconds`, and
  `avg_channel_enhancement_pass_seconds`; and
- the explicit `preflight_seconds`, `enhancing_seconds`,
  `finalizing_seconds`, and `validating_seconds` phase measurements.

Compare releases only after matching records on hardware model, model artifact,
processing profile, container/codec, input sample rate, channel count, chunk,
and overlap. This prevents a workload change from looking like a software
regression. Never use Sentry's transaction duration as processing or
enhancement duration. Require enough records before raising a regression alert,
then reproduce the suspected slowdown with the controlled release benchmark
before making a performance claim or optimization decision.

## Routine triage and governance

Crash telemetry provides a release/build, a readable stack, OS/hardware facts,
and possibly the fixed set of fields describing the active operation. Use it
to identify what to reproduce; it does not replace deterministic tests or
local support reports.

Before each public release:

- confirm symbol upload succeeded for the exact archive;
- review QA payload evidence and the 30-day retention setting;
- check quota headroom, multi-factor authentication, least-privilege access,
  source-IP suppression, and the geography scrub rule;
- confirm App Store Connect privacy answers match `PRIVACY_POLICY.md`, the
  repository privacy manifest, and the shipping SDK configuration; and
- record the QA event links, release/build, reviewer, and date in the release
  checklist.

Accepted events are not selectively deletable by a SpeechLens user because the
app sends no account identity and deletes its UUID on full revocation. They age
out under the 30-day retention policy.
