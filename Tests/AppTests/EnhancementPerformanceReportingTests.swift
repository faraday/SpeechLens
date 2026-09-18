// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import AudioToolbox
import Inference
import MediaIO
import Processing
import XCTest
@testable import App

@MainActor
final class EnhancementPerformanceReportingTests: XCTestCase {
    func testContainersMapExhaustivelyWithoutRawValueAssumptions() {
        let expected: [(MediaContainer, EnhancementPerformanceContainer)] = [
            (.wav, .wav),
            (.aiff, .aiff),
            (.caf, .caf),
            (.mp3, .mp3),
            (.m4a, .m4a),
            (.mp4, .mp4),
            (.mov, .mov),
            (.avi, .avi),
            (.flac, .flac),
        ]

        for (container, performanceContainer) in expected {
            XCTAssertEqual(
                EnhancementPerformanceContainer(container),
                performanceContainer
            )
        }
        XCTAssertEqual(EnhancementPerformanceContainer.other.rawValue, "other")
    }

    func testCodecFormatIDsMapOnlyToCoarseClasses() {
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: kAudioFormatLinearPCM),
            .pcm
        )
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: kAudioFormatMPEG4AAC),
            .aac
        )
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: kAudioFormatMPEGLayer3),
            .mp3
        )
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: kAudioFormatFLAC),
            .flac
        )
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: kAudioFormatAppleLossless),
            .alac
        )
        XCTAssertEqual(
            EnhancementPerformanceCodecClass(formatID: 0xDEAD_BEEF),
            .other
        )
    }

    func testPerformanceRevocationDuringActiveEnhancementSuppressesSubmission()
        async throws
    {
        let defaults = UserDefaults(
            suiteName: "PerformanceRevocation.\(UUID().uuidString)"
        )!
        defaults.set(
            AppOnboardingPreference.requiredVersion,
            forKey: AppOnboardingPreference.acceptedVersionKey
        )
        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        let backend = RecordingTelemetryBackend()
        let telemetry = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: .init(
                dsn: "https://public@o1.ingest.de.sentry.io/1",
                environment: "qa",
                releaseName: "dev.speechlens.SpeechLens@1.0+1",
                distribution: "1",
                cacheDirectoryURL: try makeTemporaryTestDirectory(
                    prefix: "PerformanceRevocationCache"
                )
            ),
            environment: testEnvironment,
            reporter: backend
        )
        telemetry.start(initialReport: nil)
        let context = try makeWorkflowContext(
            performanceReporter: telemetry,
            performanceEnvironment: testEnvironment,
            performanceBuildContext: .init(
                buildConfiguration: .release,
                environment: "qa"
            )
        )

        context.app.process(inputURL: context.fixture.inputURL)
        await context.service.releaseProgress()
        defaults.set(false, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }

        XCTAssertTrue(backend.records.isEmpty)
        XCTAssertEqual(backend.starts, [[.performance]])
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testSuccessfulEnhancementEmitsExactlyOneValidatedRecord() async throws {
        let reporter = RecordingPerformanceReporter()
        let context = try makeWorkflowContext(
            performanceReporter: reporter,
            performanceEnvironment: testEnvironment,
            performanceBuildContext: .init(
                buildConfiguration: .release,
                environment: "qa"
            )
        )

        context.app.process(inputURL: context.fixture.inputURL)
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }

        XCTAssertEqual(reporter.records.count, 1)
        let record = try XCTUnwrap(reporter.records.first)
        XCTAssertEqual(record.enhancementPassSeconds, 7)
        XCTAssertEqual(
            record.realTimeFactor,
            7 / record.selectedInputAudioDurationSeconds,
            accuracy: 1e-12
        )
        XCTAssertEqual(record.averageChannelEnhancementPassSeconds, 2.5)
        XCTAssertEqual(
            record.averageChannelRealTimeFactor,
            2.5 / record.selectedInputAudioDurationSeconds,
            accuracy: 1e-12
        )
        XCTAssertEqual(record.inputCodecClass, .pcm)
        XCTAssertEqual(record.outputCodecClass, .pcm)
        XCTAssertEqual(record.inputContainer, .wav)
        XCTAssertEqual(record.outputContainer, .wav)
        XCTAssertEqual(record.inputAudioSampleRateHz, 48_000)
        XCTAssertEqual(record.environment, "qa")
        XCTAssertEqual(record.buildConfiguration, .release)
        XCTAssertEqual(record.dimensions["input_audio_sample_rate_hz"], "48000")
        XCTAssertEqual(record.dimensions["channel_count"], "2")
        XCTAssertEqual(record.dimensions["chunk_seconds"], "5.0")
        XCTAssertEqual(record.dimensions["overlap_portion"], "0.05")
        XCTAssertEqual(
            record.dimensions["effective_telemetry_sample_rate"],
            "1.0"
        )
        XCTAssertEqual(
            Set(record.dimensions.keys),
            EnhancementPerformanceRecord.allowedDimensionNames.subtracting([
                "cpu_physical_cores",
                "cpu_logical_cores",
                "cpu_performance_cores",
                "cpu_efficiency_cores",
                "gpu_name",
                "gpu_core_count",
                "gpu_has_unified_memory",
                "gpu_max_working_set_gib",
            ])
        )
        XCTAssertEqual(
            Set(record.measurements.keys),
            EnhancementPerformanceRecord.allowedMeasurementNames
        )
        XCTAssertNil(record.measurements["app_operation_wall_seconds"])
        XCTAssertNil(record.measurements["committing_seconds"])
        XCTAssertEqual(
            record.measurements.count,
            10,
            "Sentry extracts at most ten custom transaction measurements."
        )
        for forbidden in [
            "url", "path", "filename", "stream_index", "codec_name",
            "fourcc", "metadata", "raw_error", "operation_uuid",
        ] {
            XCTAssertNil(record.dimensions[forbidden])
            XCTAssertNil(record.measurements[forbidden])
        }
    }

    func testFailedEnhancementEmitsNothing() async throws {
        let reporter = RecordingPerformanceReporter()
        let context = try makeWorkflowContext(
            serviceOutcome: .processingFailure,
            performanceReporter: reporter,
            performanceEnvironment: testEnvironment,
            performanceBuildContext: .init(
                buildConfiguration: .debug,
                environment: "development"
            )
        )

        context.app.process(inputURL: context.fixture.inputURL)
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .failed = $0 { return true }
            return false
        }

        XCTAssertTrue(reporter.records.isEmpty)
    }

    func testCancelledEnhancementEmitsNothing() async throws {
        let reporter = RecordingPerformanceReporter()
        let context = try makeWorkflowContext(
            performanceReporter: reporter,
            performanceEnvironment: testEnvironment,
            performanceBuildContext: .init(
                buildConfiguration: .debug,
                environment: "development"
            )
        )

        context.app.process(inputURL: context.fixture.inputURL)
        await waitUntil { await context.service.requests.count == 1 }
        context.app.cancelProcessing()
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .cancelled = $0 { return true }
            return false
        }

        XCTAssertTrue(reporter.records.isEmpty)
    }

    func testStaleCompletionIdentitySuppressesTelemetryPath() {
        let active = UUID()
        let stale = UUID()
        var reachedSubmission = false

        if AppEnhancementCompletionPolicy.isCurrent(
            activeOperationID: active,
            completingOperationID: stale
        ) {
            reachedSubmission = true
        }

        XCTAssertFalse(reachedSubmission)
        XCTAssertTrue(AppEnhancementCompletionPolicy.isCurrent(
            activeOperationID: active,
            completingOperationID: active
        ))
    }

    func testRecordRejectsInconsistentTimings() throws {
        let fixture = try WorkflowMediaFixture.make(
            root: makeTemporaryTestDirectory(prefix: "PerformanceRecord")
        )
        let source = try XCTUnwrap(fixture.results[0])
        let inconsistent = MediaProcessingResult(
            inputInfo: source.inputInfo,
            outputInfo: source.outputInfo,
            outputPlan: source.outputPlan,
            notices: source.notices,
            outputURL: source.outputURL,
            previewAssets: source.previewAssets,
            timings: .init(
                total: .seconds(10),
                preflight: .seconds(1),
                enhancing: .seconds(2),
                finalizing: .seconds(2),
                validating: .seconds(1),
                committing: .seconds(1),
                enhancementPass: .seconds(9),
                channelEnhancementPasses: [.seconds(2), .seconds(3)]
            )
        )

        XCTAssertNil(EnhancementPerformanceRecord(
            result: inconsistent,
            profile: .fast,
            settings: .standard,
            modelArtifactVersion: "model-1",
            modelSelection: .default,
            diagnosticEnvironment: testEnvironment,
            buildContext: .init(
                buildConfiguration: .release,
                environment: "qa"
            )
        ))
    }

    func testRecordRejectsZeroAndNonfiniteSelectedAudioDuration() throws {
        let fixture = try WorkflowMediaFixture.make(
            root: makeTemporaryTestDirectory(prefix: "PerformanceDuration")
        )
        let source = try XCTUnwrap(fixture.results[0])
        for invalidDuration in [0.0, Double.nan, Double.infinity] {
            let selected = source.inputInfo.selectedAudio
            let invalidAudio = AudioStreamDescriptor(
                sampleRate: selected.sampleRate,
                channelCount: selected.channelCount,
                validFrameCount: selected.validFrameCount,
                presentationStartSeconds: selected.presentationStartSeconds,
                durationSeconds: invalidDuration,
                hasTimelineDiscontinuities: selected.hasTimelineDiscontinuities,
                channelLayout: selected.channelLayout,
                codec: selected.codec,
                estimatedBitRate: selected.estimatedBitRate
            )
            let invalidInput = MediaFileInfo(
                container: source.inputInfo.container,
                durationSeconds: source.inputInfo.durationSeconds,
                tracks: source.inputInfo.tracks,
                selectedAudioStreamIndex:
                    source.inputInfo.selectedAudioStreamIndex,
                selectedAudio: invalidAudio,
                metadataItemCount: source.inputInfo.metadataItemCount
            )
            let invalidResult = MediaProcessingResult(
                inputInfo: invalidInput,
                outputInfo: source.outputInfo,
                outputPlan: source.outputPlan,
                notices: source.notices,
                outputURL: source.outputURL,
                previewAssets: source.previewAssets,
                timings: source.timings
            )

            XCTAssertNil(EnhancementPerformanceRecord(
                result: invalidResult,
                profile: .fast,
                settings: .standard,
                modelArtifactVersion: "model-1",
                modelSelection: .default,
                diagnosticEnvironment: testEnvironment,
                buildContext: .init(
                    buildConfiguration: .release,
                    environment: "qa"
                )
            ))
        }
    }

    func testOutboundPayloadRejectsUnknownOrNonfiniteFields() {
        let validMeasurements = Dictionary(
            uniqueKeysWithValues:
                EnhancementPerformanceRecord.allowedMeasurementNames.map {
                    ($0, 1.0)
                }
        )
        XCTAssertNotNil(EnhancementPerformancePayload(
            dimensions: ["input_container": "wav"],
            measurements: validMeasurements
        ))
        XCTAssertNil(EnhancementPerformancePayload(
            dimensions: ["filename": "private.wav"],
            measurements: validMeasurements
        ))
        XCTAssertNil(EnhancementPerformancePayload(
            dimensions: ["input_container": "wav"],
            measurements: validMeasurements.merging(
                ["unexpected_seconds": 1]
            ) { current, _ in current }
        ))
        var nonfinite = validMeasurements
        nonfinite["processing_total_seconds"] = .nan
        XCTAssertNil(EnhancementPerformancePayload(
            dimensions: ["input_container": "wav"],
            measurements: nonfinite
        ))
    }

    func testSentryBoundaryAcceptsOnlyExactPerformanceContract() {
        let valid = validSerializedPerformanceTransaction()
        XCTAssertTrue(
            SentryCrashReporter.isAllowedPerformanceSerialization(valid)
        )

        XCTAssertRejected(valid, changing: "type", to: "event")
        XCTAssertRejected(valid, changing: "transaction", to: "other")

        var wrongOperation = valid
        wrongOperation["contexts"] = [
            "trace": ["op": "unexpected.operation"],
        ]
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                wrongOperation
            )
        )

        var spans = valid
        spans["spans"] = [["op": "child"]]
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(spans)
        )

        var unexpectedTag = valid
        var tags = unexpectedTag["tags"] as! [String: String]
        tags["filename"] = "private.wav"
        unexpectedTag["tags"] = tags
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                unexpectedTag
            )
        )

        var missingMarker = valid
        tags = missingMarker["tags"] as! [String: String]
        tags.removeValue(forKey: "_speechlens_transaction_contract")
        missingMarker["tags"] = tags
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                missingMarker
            )
        )

        var unexpectedMeasurement = valid
        var measurements =
            unexpectedMeasurement["measurements"] as! [String: Any]
        measurements["unexpected_seconds"] = ["value": 1.0]
        unexpectedMeasurement["measurements"] = measurements
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                unexpectedMeasurement
            )
        )

        var missingMeasurement = valid
        measurements = missingMeasurement["measurements"] as! [String: Any]
        measurements.removeValue(forKey: "processing_total_seconds")
        missingMeasurement["measurements"] = measurements
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                missingMeasurement
            )
        )

        for invalidValue in [Double.nan, Double.infinity, -1] {
            var invalidMeasurement = valid
            measurements =
                invalidMeasurement["measurements"] as! [String: Any]
            measurements["processing_total_seconds"] = [
                "value": invalidValue,
            ]
            invalidMeasurement["measurements"] = measurements
            XCTAssertFalse(
                SentryCrashReporter.isAllowedPerformanceSerialization(
                    invalidMeasurement
                )
            )
        }

        var unexpectedUnit = valid
        measurements = unexpectedUnit["measurements"] as! [String: Any]
        measurements["processing_total_seconds"] = [
            "value": 1.0,
            "unit": "secret",
        ]
        unexpectedUnit["measurements"] = measurements
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(
                unexpectedUnit
            )
        )
    }

    private func validSerializedPerformanceTransaction() -> [String: Any] {
        let measurements: [String: Any] = Dictionary(
            uniqueKeysWithValues:
                EnhancementPerformanceRecord.allowedMeasurementNames.map {
                    ($0, ["value": 1.0] as [String: Any])
                }
        )
        return [
            "type": "transaction",
            "transaction": "media_enhancement",
            "contexts": [
                "trace": ["op": "speechlens.enhancement"],
            ],
            "spans": [Any](),
            "tags": [
                "_speechlens_transaction_contract":
                    "speechlens.enhancement/v1",
                "input_container": "wav",
            ],
            "measurements": measurements,
        ]
    }

    private func XCTAssertRejected(
        _ serialization: [String: Any],
        changing key: String,
        to value: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var changed = serialization
        changed[key] = value
        XCTAssertFalse(
            SentryCrashReporter.isAllowedPerformanceSerialization(changed),
            file: file,
            line: line
        )
    }

    private var testEnvironment: DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: "1.0",
            appBuild: "1",
            macOSVersion: "15.0",
            hardwareModel: "Mac15,3",
            processorCount: 10,
            physicalMemoryGiB: 16
        )
    }
}

@MainActor
private final class RecordingPerformanceReporter:
    AppEnhancementPerformanceReporting
{
    private(set) var records = [EnhancementPerformanceRecord]()

    func submit(_ record: EnhancementPerformanceRecord) {
        records.append(record)
    }
}

@MainActor
private final class RecordingTelemetryBackend: AppTelemetryReporting {
    private(set) var starts = [TelemetryCapabilities]()
    private(set) var records = [EnhancementPerformanceRecord]()
    private(set) var stopCount = 0

    func start(
        configuration: CrashReportingConfiguration,
        environment: CrashEnvironmentContext,
        context: CrashOperationContext?,
        capabilities: TelemetryCapabilities,
        userID: String
    ) {
        starts.append(capabilities)
    }

    func update(context: CrashOperationContext?) {}

    func submit(_ record: EnhancementPerformanceRecord) {
        records.append(record)
    }
    func submit(_ record: DailyActivityRecord) {}

    func stopAndPurge(cacheDirectoryURL: URL) {
        stopCount += 1
    }
}
