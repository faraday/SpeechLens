// SPDX-License-Identifier: Apache-2.0

import Foundation

func localized(
    _ resource: LocalizedStringResource,
    locale: Locale = .current
) -> String {
    var localized = resource
    localized.locale = locale
    return String(localized: localized)
}
