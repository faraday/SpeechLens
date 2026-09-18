// SPDX-License-Identifier: Apache-2.0

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: swift Tools/generate-heaac-fixture.swift <fdk-ffmpeg> <output.m4a>\n", stderr)
    exit(64)
}

let encoderURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let sampleRate = 48_000
let frameCount = sampleRate * 3
var samples = [Float]()
samples.reserveCapacity(frameCount * 2)

for frame in 0..<frameCount {
    let time = Double(frame) / Double(sampleRate)
    let left: Double
    let right: Double
    switch time {
    case ..<0.25:
        left = 0
        right = 0
    case ..<1.5:
        left = 0.25 * sin(2 * .pi * 440 * time)
        right = 0.25 * sin(2 * .pi * 880 * time)
    default:
        let sweep = 300 + 700 * (time - 1.5) / 1.5
        left = 0.2 * sin(2 * .pi * sweep * time)
        right = 0.15 * sin(2 * .pi * (sweep * 1.5) * time)
    }
    let transient = frame == sampleRate * 2 ? 0.5 : 0
    samples.append(Float(left + transient))
    samples.append(Float(right - transient))
}

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "SpeechLens-HEAAC-\(UUID().uuidString)", isDirectory: true
)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let rawURL = temporaryDirectory.appendingPathComponent("fixture.f32le")
try samples.withUnsafeBufferPointer { buffer in
    try Data(buffer: buffer).write(to: rawURL, options: .atomic)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)
let process = Process()
process.executableURL = encoderURL
process.arguments = [
    "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
    "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", rawURL.path,
    "-c:a", "libfdk_aac", "-profile:a", "aac_he", "-b:a", "48000",
    "-movflags", "+faststart", "-f", "mp4", outputURL.path,
]
process.standardInput = FileHandle.nullDevice
let error = Pipe()
process.standardError = error
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    let message = String(
        data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? "unknown encoder failure"
    fputs("HE-AAC fixture encoding failed: \(message)\n", stderr)
    exit(process.terminationStatus)
}
