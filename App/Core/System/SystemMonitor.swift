// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

actor SystemMonitor {
    func snapshot() -> SystemSnapshot {
        let storage = storageCapacity()
        let memory = memoryUsage()

        return SystemSnapshot(
            storageTotal: storage.total,
            storageAvailable: storage.available,
            memoryTotal: memory.total,
            memoryUsed: memory.used,
            capturedAt: Date()
        )
    }

    private func storageCapacity() -> (total: Int64, available: Int64) {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            return (
                Int64(values.volumeTotalCapacity ?? 0),
                values.volumeAvailableCapacityForImportantUsage ?? 0
            )
        } catch {
            return (0, 0)
        }
    }

    private func memoryUsage() -> (total: Int64, used: Int64) {
        let total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (total, 0) }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return (total, 0)
        }

        let pages = UInt64(statistics.active_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let used = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        let measured = Int64(clamping: used.overflow ? UInt64.max : used.partialValue)
        return (total, min(measured, total))
    }
}
