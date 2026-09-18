// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO
import SwiftUI

struct DisclosureHeader: View {
    let title: LocalizedStringResource
    let isExpanded: Bool
    let trailingSummary: LocalizedStringResource?
    let action: () -> Void

    init(
        title: LocalizedStringResource,
        isExpanded: Bool,
        trailingSummary: LocalizedStringResource? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.trailingSummary = trailingSummary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 10)
                Text(title).font(.subheadline)
                Spacer()
                if let trailingSummary {
                    Text(trailingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(
            Text(
                isExpanded
                    ? LocalizedStringResource.settingsDisclosureExpanded
                    : LocalizedStringResource.settingsDisclosureCollapsed
            )
        )
    }
}

extension Text {
    func sectionLabelStyle() -> some View {
        font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    return Duration.seconds(seconds.rounded()).formatted(
        .time(pattern: .minuteSecond)
    )
}

func formatElapsedDuration(
    _ seconds: Double,
    locale: Locale = .current
) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return localized(.formatElapsedSeconds(0), locale: locale)
    }
    let total = Int(seconds.rounded())
    if total < 60 {
        return localized(.formatElapsedSeconds(total), locale: locale)
    }
    let minutes = total / 60
    let remainingSeconds = total % 60
    return localized(
        .formatElapsedMinutesSeconds(minutes, remainingSeconds),
        locale: locale
    )
}

func formatSampleRate(
    _ sampleRate: Int,
    locale: Locale = .current
) -> String {
    let style = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0...1))
        .locale(locale)
    let formatted = (Double(sampleRate) / 1_000).formatted(style)
    return localized(.formatSampleRateKhz(formatted), locale: locale)
}

func channelLayoutLabel(
    _ channelCount: Int,
    locale: Locale = .current
) -> String {
    let resource: LocalizedStringResource
    switch channelCount {
    case 1:
        resource = LocalizedStringResource.formatChannelLayoutMono
    case 2:
        resource = LocalizedStringResource.formatChannelLayoutStereo
    default:
        resource = .formatChannelLayoutChannels(channelCount)
    }
    return localized(resource, locale: locale)
}

func audioTrackLabel(_ track: MediaAudioTrackOption, locale: Locale = .current) -> String {
    let languageCode = track.languageCode?.split(separator: "-").first.map(String.init)
    let base = track.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? languageCode.flatMap { locale.localizedString(forLanguageCode: $0) }
        ?? localized(.mediaTrackOrdinal(track.ordinal), locale: locale)
    guard let audio = track.audioDescriptor else {
        let unavailable = localized(
            LocalizedStringResource.mediaTrackUnavailableSuffix,
            locale: locale
        )
        return "\(base) - \(unavailable)"
    }
    return "\(base) · \(channelLayoutLabel(audio.channelCount, locale: locale))"
}

func audioTrackLabel(
    _ track: MediaAudioTrackOption,
    among tracks: [MediaAudioTrackOption],
    locale: Locale = .current
) -> String {
    let label = audioTrackLabel(track, locale: locale)
    let duplicateCount = tracks.filter { audioTrackLabel($0, locale: locale) == label }.count
    guard duplicateCount > 1 else { return label }
    let ordinal = localized(.mediaTrackDisambiguation(track.ordinal), locale: locale)
    return "\(label) · \(ordinal)"
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension ModelSetupState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
