# Telemetry Contract

This document is the stable technical contract for telemetry in the SpeechLens
macOS app. It describes shipping behavior. Operational setup and release QA are
covered in [Sentry Operations](sentry-operations.md).

The CLI and the `Diagnostics`, `Processing`, `Inference`, `MediaIO`, and
`AudioIO` modules do not report over the network. Only the App target links to
Sentry. The `AppTelemetryReporting` protocol isolates that dependency so the
reporter can be replaced without introducing Sentry into the rest of the app.

## Invariants

- SpeechLens sends a category of data only after the user has enabled that
  category and accepted the current onboarding disclosure.
- Sending happens in the background and is best-effort. A network, Sentry, or
  serialization failure must not block enhancement, retry the media operation,
  report a workflow failure, or alter the output.
- Telemetry must not change output bytes, frame count, sample rate, channel
  scheduling, or the MLX/Metal inference path. In particular,
  `output.sampleRate == input.sampleRate` remains unconditional.
- Audio, media content, filenames, paths, URLs, transcripts, raw handled
  errors, arbitrary logs, arbitrary media metadata, and the local diagnostic
  snapshot are never sent.
- SpeechLens builds dedicated records with fixed fields for each telemetry
  category. It never sends an entire `DiagnosticReport`, attaches
  `latest-operation.json`, automatically copies fields from other objects, or
  forwards an error's `localizedDescription`.
- SpeechLens does not rely on Sentry's default collection behavior. A crash
  event or transaction is sent only when the user has enabled that category
  and SpeechLens's final pre-send check confirms that the payload contains only
  allowed data. Release-health sessions follow a separate rule: the SDK enables
  them only while crash reporting is enabled.

## Consent and reporting categories

Telemetry has three independently enforced stored permissions:

| Reporting category | Preference key | Default | Outbound data |
| --- | --- | ---: | --- |
| Native crash reporting | `telemetry.crashReportingEnabled` | On | Unhandled native crash events and release-health sessions |
| Basic diagnostics | `telemetry.basicDiagnosticsEnabled` | On | At most one daily activity transaction per UTC day |
| Enhancement performance | `telemetry.enhancementPerformanceEnabled` | On | One measurement-only transaction after an eligible successful enhancement |

The UI presents crash reporting and basic diagnostics as one reliability
control, but runtime policy reads the two keys separately. Performance consent
is independent and is never inferred from reliability consent.

Showing a switch as on by default does not itself grant permission. The user
must accept the current onboarding disclosure, version 4, before Sentry can
start or send data. Reporting also stays off if its configuration is missing
or invalid. The DSN, which is the Sentry project's upload address, must be an
HTTPS Frankfurt endpoint under `ingest.de.sentry.io`. The environment must be
`development`, `qa`, or `production`.

Automatic Sentry sessions are enabled only when native crash reporting is
enabled. A session records whether an app run ended in a crash and is used for
crash-free release statistics. Session counts are not used for daily active
installs (DAU) or monthly active installs (MAU).

## Identity and lifecycle

Events and transactions set only a random UUID v4 as Sentry `user.id`. It is
not derived from an account, hardware, a device name, or a filesystem value.
The UUID remains stable for the current consent epoch while any telemetry
category is enabled. A consent epoch is one uninterrupted period during which
at least one telemetry category remains enabled.

When every reporting category is disabled, SpeechLens immediately closes the
SDK, purges all telemetry caches, removes the UUID and daily-activity marker,
and makes no new telemetry request. Re-enabling creates a new UUID and does not
send historical local diagnostics or events from a deleted cache.

Each possible non-empty combination of the three permissions uses its own
predictably named cache directory. When a permission changes, SpeechLens
cancels the current network session, deletes both the old combination's cache
and the new combination's cache, and starts Sentry again. As a result, the app
may discard a queued event even when its category remains enabled. If the
permission combination has not changed, pending events survive an app
relaunch. The cache holds at most five envelopes, Sentry's term for queued
payload packages. Sentry Cocoa deletes a cached envelope after at most 90 days.

Revocation cannot selectively remove events already accepted by Sentry. They
expire under the organization's 30-day retention policy. SpeechLens cannot
promise per-user server deletion because it has neither an account identity
nor a durable identifier after full revocation.

## Native crash event

Native crash events are controlled by crash consent. The final filter accepts
only a native exception or signal that Sentry marks `handled == false`. In
plain terms, the app must have crashed; an error or exception caught by the app
does not qualify and is rejected.

The event retains the native exception or signal type, thread stacks, debug
images needed to turn memory addresses into function names, Sentry
release/build identity, and two SpeechLens-owned context blocks with fixed
field sets:

- `speechlens_environment`: `event_schema_version`, `app_version`,
  `app_build`, `macos_version`, `hardware_model`, `processor_count`,
  `physical_memory_gib`, `cpu_physical_cores`, `cpu_logical_cores`,
  `cpu_performance_cores`, `cpu_efficiency_cores`, `gpu_name`,
  `gpu_core_count`, `gpu_has_unified_memory`, and
  `gpu_max_working_set_gib`.
- `speechlens_operation`: `event_schema_version`, `operation`, `phase`,
  `model_artifact_version`, `model_selection`, `processing_profile`,
  `chunk_seconds`, and `overlap_portion`.

The operation context exists only while a local diagnostic report is in
progress. String values are limited to 128 UTF-8 bytes and rejected if they
look like a path, URL, or multiline value.

Before transmission, SpeechLens removes all data outside the crash contract,
including:

- messages, raw errors, logger/server names, transaction names, tags, extras,
  SDK metadata, module lists, and grouping fingerprints;
- breadcrumbs, request data, and attachments;
- exception values and internal mechanism details; and
- thread names, source filenames and packages, nearby source text, and local
  frame variables.

For a debug image, a full code path is reduced to its final filename.

## Daily activity transaction

Basic diagnostics emits this exact Sentry transaction at most once per UUID per
UTC day, on launch or meaningful use. It is a single top-level event with no
child timing spans:

- transaction: `app_daily_active`
- operation: `speechlens.activity`
- event schema: 1
- sampling: every eligible record is selected (100%);
  `effective_telemetry_sample_rate = 1.0`
- dimensions: `event_schema_version`, `app_version`, `app_build`,
  `macos_version`, `hardware_model`, and
  `effective_telemetry_sample_rate`

The transaction must have no child spans, exceptions, measurements, request,
breadcrumbs, stack data, debug metadata, or unapproved labels. The adapter adds
an internal marker so the final filter can recognize this exact transaction;
the filter removes that marker before sending.

## Enhancement performance transaction

Performance consent authorizes one transaction after a user-requested
enhancement has successfully committed its output. Failed, cancelled, stale,
model-download, playback, seeking, and waveform-only operations send no
performance record. Timings come from `Processing` and use a monotonic clock,
which cannot jump when the system clock changes. SpeechLens constructs and
submits the record only after the measured operation has ended.

The transaction has this exact identity:

- transaction: `media_enhancement`
- operation: `speechlens.enhancement`
- event schema: 3
- sampling: every eligible record is selected (100%);
  `effective_telemetry_sample_rate = 1.0`

The ten required measurements are:

| Measurement | Meaning |
| --- | --- |
| `selected_input_audio_duration_seconds` | Selected input stream duration |
| `processing_total_seconds` | Total time spent in the file-processing pipeline |
| `preflight_seconds` | Inspection and setup phase |
| `enhancing_seconds` | Enhancement phase |
| `finalizing_seconds` | Output finalization phase |
| `validating_seconds` | Structural validation phase |
| `enhancement_pass_seconds` | Whole-file enhancement pass wall time |
| `real_time_factor` | Enhancement pass divided by input duration |
| `avg_channel_enhancement_pass_seconds` | Mean serial per-channel enhancement pass |
| `avg_channel_real_time_factor` | Mean per-channel pass divided by input duration |

All measurements must be finite and non-negative, and the set must match
exactly. The following dimension keys provide labels for grouping and comparing
records:

- `event_schema_version`, `effective_telemetry_sample_rate`;
- `input_container`, `output_container`, `input_codec_class`,
  `output_codec_class`, `input_audio_sample_rate_hz`, `channel_count`;
- `processing_profile`, `chunk_seconds`, `overlap_portion`;
- `model_artifact_version`, `model_selection`;
- `app_version`, `app_build`, `build_configuration`,
  `telemetry_environment`, `macos_version`;
- `hardware_model`, `processor_count`, `physical_memory_gib`,
  `cpu_physical_cores`, `cpu_logical_cores`, `cpu_performance_cores`,
  `cpu_efficiency_cores`; and
- `gpu_name`, `gpu_core_count`, `gpu_has_unified_memory`,
  `gpu_max_working_set_gib`.

Dimension strings use the same 128-byte/path/URL/newline restrictions as the
other records. Production performance records are valid only from a Release
build. The transaction has no child spans. Sentry may display the transaction
itself as lasting almost no time because SpeechLens creates it only to carry
the completed measurements. Use the explicit measurements above—never that
displayed transaction duration—to analyze enhancement performance.

## SDK collection boundary

SpeechLens turns off Sentry features that are outside this contract:

- default personally identifiable information and client outcome reports
  (the SDK's delivery statistics);
- breadcrumbs, logs, failed-network-request capture, and automatic interception
  through method or data swizzling;
- automatic network, file-I/O, Core Data, and general performance tracing;
- app-hang, watchdog, `SIGTERM`, and MetricKit diagnostics;
- profiling, metrics, persisted crash traces, Swift async stack traces, and
  crash-memory inspection.

When the active operation changes, SpeechLens clears shared tags, extra fields,
breadcrumbs, and attachments before setting the new operation context. The
final filter also excludes screenshots, view hierarchy, session replay data,
attachments, and every field that is not specifically allowed. Automatic trace
sampling is set to zero. Only the two transactions created directly by
SpeechLens—daily activity and enhancement performance—receive an explicit
decision to send.

The fixed release name is
`dev.speechlens.SpeechLens@<marketing-version>+<build>`, with the build number
also used as Sentry distribution. Debug builds use `development`, signed QA
builds may use `qa`, and official Release archives use `production`.

## Local diagnostics are separate

`DiagnosticReport` and
`~/Library/Application Support/SpeechLens/Diagnostics/latest-operation.json`
remain local support state regardless of telemetry consent. Local recording is
vendor-neutral and network-free. See the `Diagnostics` module documentation
for its schema and recovery behavior.

## Change control

Any change to consent semantics, event names, allowed fields, sampling,
identity, cache behavior, automatic SDK integrations, data region, retention,
or the Sentry dependency is a contract change. It requires source and payload
tests, an SDK/payload audit, and review of `PRIVACY_POLICY.md`,
`PrivacyInfo.xcprivacy`, onboarding/settings copy, and
[Sentry Operations](sentry-operations.md).
