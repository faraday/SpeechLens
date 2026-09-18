// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

final class ArchTests: XCTestCase {
    func testInferenceDoesNotDependOnMediaOrAudioIO() throws {
        let text = try sourceText("Sources/Inference")
        XCTAssertFalse(text.contains("import AudioIO"))
        XCTAssertFalse(text.contains("import MediaIO"))
        XCTAssertFalse(text.contains("import Processing"))
    }

    func testSharedDiagnosticsAndCLIDoNotDependOnAppUI() throws {
        let diagnostics = try sourceText("Sources/Diagnostics")
        let cli = try sourceText("Sources/CLI")
        for forbidden in ["import App", "import AppKit", "import SwiftUI"] {
            XCTAssertFalse(diagnostics.contains(forbidden))
            XCTAssertFalse(cli.contains(forbidden))
        }
    }

    func testSentryDependencyAndImportsRemainAppOnly() throws {
        let root = projectRoot()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            package.localizedCaseInsensitiveContains("sentry"),
            "Sentry must not enter the shared Swift package graph"
        )

        let lowerModules = try [
            "Sources/Diagnostics",
            "Sources/CLI",
            "Sources/Processing",
            "Sources/Inference",
            "Sources/MediaIO",
            "Sources/AudioIO",
        ].map { try sourceText($0) }.joined()
        XCTAssertFalse(lowerModules.contains("import Sentry"))
        XCTAssertFalse(lowerModules.contains("SpeechLensSentryDSN"))

        let appRoot = root.appendingPathComponent("Sources/App")
        let sentryImports = try FileManager.default.contentsOfDirectory(
            at: appRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("import Sentry")
        }.map(\.lastPathComponent)
        XCTAssertEqual(sentryImports, ["SentryCrashReporter.swift"])

        let project = try String(
            contentsOf: root.appendingPathComponent(
                "SpeechLens.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("sentry-cocoa"))
        let testTarget = try XCTUnwrap(project.range(
            of: "100000000000000000000011 /* SpeechLensAppTests */ = {"
        ))
        let endTargets = try XCTUnwrap(project.range(
            of: "/* End PBXNativeTarget section */"
        ))
        let testTargetText = project[testTarget.lowerBound..<endTargets.lowerBound]
        XCTAssertFalse(testTargetText.contains("/* Sentry */"))

        let adapter = try String(
            contentsOf: appRoot.appendingPathComponent(
                "SentryCrashReporter.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(adapter.contains("options.tracesSampleRate = 0"))
        XCTAssertTrue(adapter.contains("options.tracesSampler = nil"))
        XCTAssertTrue(adapter.contains("options.beforeSendSpan = { _ in nil }"))
        XCTAssertTrue(adapter.contains("bindToScope: false"))
        XCTAssertTrue(adapter.contains("name: \"media_enhancement\""))
        XCTAssertTrue(adapter.contains("operation: \"speechlens.enhancement\""))
    }

    func testApplicationLaunchDoesNotAutomaticallyDownloadModel() throws {
        let appLaunch = try String(
            contentsOf: projectRoot().appendingPathComponent(
                "Sources/App/SpeechLensApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(appLaunch.contains("downloadModel()"))
    }

    func testAppUsesSharedDiagnosticsWithoutRedefiningTheSchema() throws {
        let app = try sourceText("Sources/App")
        XCTAssertTrue(app.contains("import Diagnostics"))
        for forbiddenImport in ["import Metal", "import MetalKit", "import IOKit"] {
            XCTAssertFalse(
                app.contains(forbiddenImport),
                "Platform diagnostic collection belongs to Diagnostics: \(forbiddenImport)"
            )
        }
        for forbiddenDeclaration in [
            "enum AppFailureCode",
            "struct AppDiagnosticReport",
            "struct AppDiagnosticFailure",
            "struct AppDiagnosticMediaFacts",
            "final class AppDiagnosticSnapshotStore",
            "enum AppDiagnosticReportRenderer",
        ] {
            XCTAssertFalse(
                app.contains(forbiddenDeclaration),
                "Diagnostics schema belongs to the Diagnostics module: \(forbiddenDeclaration)"
            )
        }
    }

    func testMediaIOContainsFocusedAppleAACDecoder() throws {
        let root = projectRoot().appendingPathComponent("Sources/MediaIO")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("AppleAACPCMDecoder.swift"))
    }

    func testRetiredMediaBackendAbstractionsStayRemoved() throws {
        let root = projectRoot().appendingPathComponent("Sources/MediaIO")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for forbidden in [
            "AppleMediaJobBackend.swift",
            "MediaTrackRemuxer.swift",
            "MediaMetadataTransfer.swift",
            "AudioEncodingPlanner.swift",
            "MP3FormatProfile.swift",
            "AVIFormatProfile.swift",
            "NativeFLACFormatProfile.swift",
            "FFmpegProfileContracts.swift",
            "UnifiedFFmpegFormatProfile.swift",
            "MediaJobBackend.swift",
            "BackendContracts.swift",
        ] {
            XCTAssertFalse(names.contains(forbidden), "\(forbidden) must remain deleted")
        }
        let text = try sourceText("Sources/MediaIO")
        XCTAssertFalse(text.contains("VideoOutputPreference"))
        XCTAssertFalse(text.contains("cannotPreserveTracks"))
        XCTAssertFalse(text.contains("FFmpegMediaJobBackend"))
        XCTAssertFalse(text.contains("MediaJobBackend"))
        XCTAssertFalse(text.contains("AudioDecoderRegistry"))
    }

    func testProcessingOwnsTransactionAndInferenceRemainsMLXOnly() throws {
        let processing = try sourceText("Sources/Processing")
        XCTAssertTrue(processing.contains("MediaTransactionWorkspace"))
        let inference = try sourceText("Sources/Inference")
        XCTAssertFalse(inference.contains("import PyTorch"))
        XCTAssertFalse(inference.contains("CoreML"))
    }

    func testInferenceRequiresFixedMetalSelectiveScanWithoutRuntimeFallback() throws {
        let inference = try sourceText("Sources/Inference")
        XCTAssertFalse(inference.contains("preconditionFailure"))
        XCTAssertFalse(inference.contains("selectiveScanFallback"))
        XCTAssertFalse(inference.contains("SPEECHLENS_DISABLE_METAL_SSM"))
        XCTAssertFalse(inference.contains("SPEECHLENS_USE_METAL_SSM"))
    }

    func testInferenceScopesModelSetupAndExecutionToGPU() throws {
        let inference = try String(
            contentsOf: projectRoot().appendingPathComponent("Sources/Inference/Inference.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(inference.contains("Device.withDefaultDevice(.gpu"))
        XCTAssertTrue(inference.contains("self.model = try MLXExecutionContext.withGPU"))
        XCTAssertTrue(inference.contains("let output = try MLXExecutionContext.withGPU"))
        XCTAssertFalse(inference.contains("Device.setDefault"))
    }

    func testMaintainedDocumentationDoesNotAdvertiseRetiredInferenceControls() throws {
        let documentation = try documentationText(["docs"])
        for retiredControl in [
            "SPEECHLENS_PROFILE",
            "SPEECHLENS_STAGE_PROFILE",
            "SPEECHLENS_MEM_PROFILE",
            "SPEECHLENS_ENABLE_COMPILE",
            "SPEECHLENS_DISABLE_MAMBA_COMPILE",
            "SPEECHLENS_SELECTIVE_SCAN_VARIANT",
            "SPEECHLENS_DISABLE_DENSE_EVAL",
        ] {
            XCTAssertFalse(
                documentation.contains(retiredControl),
                "Maintained documentation must not advertise retired control \(retiredControl)"
            )
        }
    }

    func testKernelDocumentationDescribesMandatoryFixed16MetalScan() throws {
        let documentation = try String(
            contentsOf: projectRoot().appendingPathComponent("docs/kernel-optimization.md"),
            encoding: .utf8
        )
        XCTAssertTrue(documentation.contains("Fixed-16\nMetal selective scan is mandatory"))
        XCTAssertTrue(documentation.contains("There is no MLX selective-scan fallback"))
        XCTAssertFalse(documentation.contains("The MLX scan\nremains available"))
    }

    func testPackageNameGrantedOnlyToTestTarget() throws {
        let pbxproj = try String(
            contentsOf: projectRoot().appendingPathComponent(
                "SpeechLens.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let sections = buildSettingsSections(in: pbxproj)
        let appSections = sections.filter {
            $0.contains("PRODUCT_MODULE_NAME = App")
        }
        let testSections = sections.filter {
            $0.contains("BUNDLE_LOADER = \"$(TEST_HOST)\"")
        }

        XCTAssertFalse(appSections.isEmpty, "Expected app build settings sections")
        XCTAssertFalse(testSections.isEmpty, "Expected test build settings sections")

        for section in appSections {
            XCTAssertFalse(
                section.contains("SWIFT_PACKAGE_NAME"),
                "Production App target must not set SWIFT_PACKAGE_NAME"
            )
        }
        for section in testSections {
            XCTAssertTrue(
                section.contains("SWIFT_PACKAGE_NAME = speechlens"),
                "SpeechLensAppTests must set SWIFT_PACKAGE_NAME = speechlens"
            )
        }
    }

    private func buildSettingsSections(in pbxproj: String) -> [String] {
        var sections = [String]()
        var current: String?
        for line in pbxproj.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "buildSettings = {" {
                current = ""
            } else if let partial = current {
                if trimmed == "};" {
                    sections.append(partial)
                    current = nil
                } else {
                    current = partial + line + "\n"
                }
            }
        }
        return sections
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let root = projectRoot().appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        var result = ""
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                result += try String(contentsOf: url, encoding: .utf8)
            }
        }
        return result
    }

    private func documentationText(_ relativePaths: [String]) throws -> String {
        var result = ""
        for relativePath in relativePaths {
            let root = projectRoot().appendingPathComponent(relativePath)
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "md" else { continue }
                result += try String(contentsOf: url, encoding: .utf8)
            }
        }
        return result
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
