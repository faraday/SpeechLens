// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A non-empty, bounded block of equal-length physical audio channels.
public struct PlanarAudioBlock: Sendable, Equatable {
    public let channels: [[Float]]

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels[0].count }

    public init(channels: [[Float]]) throws {
        guard let frameCount = channels.first?.count else {
            throw AudioIOError.invalidBuffer("at least one channel is required")
        }
        guard frameCount > 0 else {
            throw AudioIOError.invalidBuffer("stream blocks must contain at least one frame")
        }
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            throw AudioIOError.invalidBuffer("all channels must have the same frame count")
        }
        self.channels = channels
    }
}

/// Supported audio file formats.
public enum AudioFormat: Sendable, Equatable {
    case wav
    case aiff
    case caf
    case unknown(String)
}

/// Errors produced by AudioIO operations.
public enum AudioIOError: Error, Sendable, Equatable {
    case invalidBuffer(String)
    case fileNotFound(String)
    case unsupportedFormat(String)
    case readFailed(String)
    case writeFailed(String)
}
