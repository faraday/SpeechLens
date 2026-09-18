// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO
import Processing

struct OutputDetail {
    let message: LocalizedStringResource
    let severity: MediaOutputNoticeSeverity

    init(
        message: LocalizedStringResource,
        severity: MediaOutputNoticeSeverity = .information
    ) {
        self.message = message
        self.severity = severity
    }
}

enum OutputDetailsBuilder {
    static func build(
        preparedJob: PreparedMediaJob,
        notices: [MediaOutputNotice]
    ) -> [OutputDetail] {
        let info = preparedJob.inputInfo
        let plan = preparedJob.outputPlan
        let outputContainer = plan.outputContainer.rawValue.uppercased()
        var details = [
            OutputDetail(
                message: .outputDetailFormat(outputContainer)
            )
        ]

        if info.isVideo {
            details.append(
                OutputDetail(message: .outputDetailVideoCopied)
            )
        }
        if info.audioTrackCount > 1 {
            details.append(
                OutputDetail(message: .outputDetailOtherAudioCopied)
            )
        }
        if plan.usesFallbackContainer {
            details.append(
                OutputDetail(
                    message: .outputDetailFallbackCompatibility(outputContainer)
                )
            )
        }
        let renderedNotices = notices.map { notice in
            OutputDetail(
                message: AppMediaNoticePresentation.message(for: notice),
                severity: notice.severity
            )
        }
        details.append(contentsOf: renderedNotices.filter { notice in
            !details.contains { $0.message == notice.message }
        })

        let hasMeaningfulDetail = details.count > 1
            || info.isVideo
            || info.container != plan.outputContainer
        return hasMeaningfulDetail ? details : []
    }
}

enum AppMediaNoticePresentation {
    static func message(
        for notice: MediaOutputNotice
    ) -> LocalizedStringResource {
        switch notice {
        case .auxiliaryStreamsOmitted:
            return LocalizedStringResource.mediaNoticeAuxiliaryStreamsOmitted
        case .fallbackContainer(_, let output):
            let outputExtension = output.preferredExtension.uppercased()
            return .mediaNoticeFallbackContainer(outputExtension)
        }
    }
}
