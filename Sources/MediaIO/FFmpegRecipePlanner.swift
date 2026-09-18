// SPDX-License-Identifier: Apache-2.0

import Foundation

struct FFmpegRecipePlanner {
    let inputContainer: MediaContainer

    func plans(
        info: MediaFileInfo,
        context: FFmpegInspectionContext
    ) throws -> [UnifiedMediaPlan] {
        guard context.container == inputContainer,
              info.container == inputContainer else {
            throw MediaIOError.invalidAudioFormat(
                "unified FFmpeg inspection context changed"
            )
        }
        let builder = FFmpegMediaPlanBuilder()
        return try FFmpegRecipePolicy.recipes(for: info).map {
            try builder.build(info: info, context: context, recipe: $0)
        }
    }

    func validateOutputURL(_ url: URL, plan: MediaOutputPlan) throws {
        let actual = MediaContainer.from(pathExtension: url.pathExtension)
        guard actual == plan.outputContainer else {
            throw MediaIOError.outputContainerMismatch(
                expected: plan.outputContainer.preferredExtension,
                actual: url.pathExtension
            )
        }
    }
}
