import Foundation
import Darwin

final class MemoryMonitor: Monitor {

    private var totalPhysicalMemory: UInt64 = 0
    private var pageSize: vm_size_t = 0

    init() {
        var pageSize32: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize32) == KERN_SUCCESS {
            pageSize = pageSize32
        }

        var sysInfo = sysctl_query("hw.memsize")
        if let data = sysInfo {
            totalPhysicalMemory = data.withUnsafeBytes { $0.load(as: UInt64.self) }
        }
    }

    func snapshot() -> Any {
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &vmStat) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard kr == KERN_SUCCESS else {
            return MemoryMetric.zero
        }

        let pages = UInt64(pageSize)

        // 对齐活动监视器口径：
        //   App 内存 = 匿名页(internal) − 可清除页(purgeable)
        //   已用     = App 内存 + 联动(wired) + 已压缩(compressed)
        //   缓存文件 = 文件页(external) + 可清除页(purgeable)
        let wired = UInt64(vmStat.wire_count) * pages
        let compressed = UInt64(vmStat.compressor_page_count) * pages
        let internalBytes = UInt64(vmStat.internal_page_count) * pages
        let purgeable = UInt64(vmStat.purgeable_count) * pages
        let external = UInt64(vmStat.external_page_count) * pages

        let appMemory = internalBytes > purgeable ? internalBytes - purgeable : 0
        let used = appMemory + wired + compressed
        let cachedFiles = external + purgeable
        let available = totalPhysicalMemory > used ? totalPhysicalMemory - used : 0

        let swapUsed = readSwapUsage()

        return MemoryMetric(
            total: totalPhysicalMemory,
            used: used,
            free: available,
            wired: wired,
            compressed: compressed,
            appMemory: appMemory,
            cachedFiles: cachedFiles,
            swapUsed: swapUsed
        )
    }

    private func readSwapUsage() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let name = "vm.swapusage"
        let result = name.withCString { cName -> Int32 in
            sysctlbyname(cName, &swapUsage, &size, nil, 0)
        }
        return result == 0 ? swapUsage.xsu_used : 0
    }

    private func sysctl_query(_ name: String) -> Data? {
        var size: Int = 0
        let result = name.withCString { cName -> Int32 in
            sysctlbyname(cName, nil, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }

        var data = Data(count: size)
        let result2 = data.withUnsafeMutableBytes { rawBuf -> Int32 in
            name.withCString { cName in
                sysctlbyname(cName, rawBuf.baseAddress, &size, nil, 0)
            }
        }
        return result2 == 0 ? data : nil
    }
}
