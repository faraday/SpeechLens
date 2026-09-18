// SPDX-License-Identifier: Apache-2.0

package protocol NativeRateAudioSource: AnyObject {
    var descriptor: AudioStreamDescriptor { get }
    func read(maxFrameCount: Int) throws -> TimedPlanarAudioBlock?
    func close()
}

package protocol NativeRateAudioSink: AnyObject {
    var writtenFrameCount: Int64 { get }

    nonisolated(nonsending)
    func append(_ block: TimedPlanarAudioBlock) async throws

    nonisolated(nonsending)
    func close() async throws
    func cancel()
}

package struct AudioSinkConfiguration: Sendable, Equatable {
    package let container: MediaContainer
    package let codecFormatID: UInt32
    package let channelLayout: AudioChannelLayoutDescriptor

    package init(outputPlan: MediaOutputPlan) {
        let encoding = outputPlan.audioEncoding
        container = encoding.container
        codecFormatID = encoding.codecFormatID
        channelLayout = encoding.channelLayout
    }
}
