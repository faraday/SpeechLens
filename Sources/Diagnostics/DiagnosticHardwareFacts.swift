// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import IOKit
import Metal

extension DiagnosticHardwareFacts {
    /// Collects local hardware facts for a sanitized diagnostic report.
    /// Missing platform details remain optional rather than making diagnostics fail.
    public static func current(
        processInfo: ProcessInfo = .processInfo
    ) -> Self {
        let device = MTLCreateSystemDefaultDevice()
        return Self(
            cpuPhysicalCores: sysctlInt("hw.physicalcpu") ?? processInfo.processorCount,
            cpuLogicalCores: sysctlInt("hw.logicalcpu") ?? processInfo.processorCount,
            cpuPerformanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            cpuEfficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
            gpuName: device?.name,
            gpuCoreCount: queryAppleSiliconGPUCoreCount(),
            gpuHasUnifiedMemory: device?.hasUnifiedMemory,
            gpuMaxWorkingSetGiB: device.map {
                Int($0.recommendedMaxWorkingSetSize / (1_024 * 1_024 * 1_024))
            }
        )
    }

    static func hardwareModelName() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: content, as: UTF8.self)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func queryAppleSiliconGPUCoreCount() -> Int? {
        let match = IOServiceMatching("IOGPU")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let currentEntry = entry
            entry = IOIteratorNext(iterator)
            if let count = IORegistryEntryCreateCFProperty(
                currentEntry,
                "gpu-core-count" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Int {
                IOObjectRelease(currentEntry)
                return count
            }
            IOObjectRelease(currentEntry)
        }
        return nil
    }
}
