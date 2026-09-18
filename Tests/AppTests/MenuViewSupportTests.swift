// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import MediaIO
import XCTest
@testable import App

final class MenuViewSupportTests: XCTestCase {
    func testReadableMediaFormatting() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(formatSampleRate(48_000, locale: locale), "48 kHz")
        XCTAssertEqual(formatSampleRate(44_100, locale: locale), "44.1 kHz")
        XCTAssertEqual(channelLayoutLabel(1, locale: locale), "Mono")
        XCTAssertEqual(channelLayoutLabel(2, locale: locale), "Stereo")
        XCTAssertEqual(channelLayoutLabel(6, locale: locale), "6 channels")
        XCTAssertEqual(formatElapsedDuration(11.2, locale: locale), "11 s")
        XCTAssertEqual(formatElapsedDuration(72, locale: locale), "1 min 12 s")
    }

    func testTrackLabelsUseLanguageAndDisambiguateDuplicates() {
        let audio = AudioStreamDescriptor(
            sampleRate: 48_000,
            channelCount: 2,
            validFrameCount: 48_000,
            presentationStartSeconds: 0,
            durationSeconds: 1,
            channelLayout: .init(rawData: nil, inferred: true),
            codec: .init(
                formatID: kAudioFormatLinearPCM,
                fourCC: "lpcm",
                bitsPerChannel: 32
            ),
            estimatedBitRate: nil
        )
        let tracks = [1, 2].map {
            MediaAudioTrackOption(
                streamIndex: $0,
                ordinal: $0,
                languageCode: "en",
                isEnabled: true,
                availability: .selectable(audio)
            )
        }
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            audioTrackLabel(tracks[0], among: tracks, locale: locale),
            "English · Stereo · Track 1"
        )

        let unnamed = MediaAudioTrackOption(
            streamIndex: 3,
            ordinal: 3,
            isEnabled: true,
            availability: .selectable(audio)
        )
        XCTAssertEqual(
            audioTrackLabel(unnamed, locale: locale),
            "Audio track 3 · Stereo"
        )

        let unavailable = MediaAudioTrackOption(
            streamIndex: 4,
            ordinal: 4,
            isEnabled: true,
            availability: .unavailable(reason: "/private/unsupported-codec")
        )
        let unavailableLabel = audioTrackLabel(unavailable, locale: locale)
        XCTAssertEqual(unavailableLabel, "Audio track 4 - Unavailable")
        XCTAssertFalse(unavailableLabel.contains("/private"))
    }
}
