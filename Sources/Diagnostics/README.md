# Diagnostics Module

## Responsibility

Owns the versioned, sanitized operation-report schema shared by the app and
CLI: stable failure codes, report rendering, atomic snapshot persistence,
recovery of interrupted operations, and local hardware facts.

## Boundaries

`DiagnosticRecorder` records an operation using `DiagnosticEnvironment`,
`DiagnosticReport`, and typed diagnostic facts. `DiagnosticSnapshotStore`
persists the latest report. `DiagnosticHardwareFacts.current()` supplies
optional platform hardware details for default environments.

## Prohibitions

- No UI copy, presentation, or AppKit/SwiftUI dependencies.
- No network reporting, uploads, telemetry preference handling, or support
  transport.
- No audio content, filenames, paths, raw error descriptions, or arbitrary
  logs in reports.
- No processing policy or mutation of media, model, or output transactions.

See [Architecture](../../docs/architecture.md) for the canonical module
ownership table.
