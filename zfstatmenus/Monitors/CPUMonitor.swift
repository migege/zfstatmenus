import Foundation
import Darwin

final class CPUMonitor: Monitor {

    private var numCores: natural_t = 0
    private var prevCpuInfo: processor_info_array_t?
    private var prevNumCpuInfo: mach_msg_type_number_t = 0

    init() {
        initialSample()
    }

    private func initialSample() {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cores,
            &info,
            &count
        )
        if result == KERN_SUCCESS {
            numCores = cores
            prevCpuInfo = info
            prevNumCpuInfo = count
        }
    }

    func snapshot() -> Any {
        var newNumCores: natural_t = 0
        var newInfoRaw: processor_info_array_t?
        var newCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &newNumCores,
            &newInfoRaw,
            &newCount
        )

        guard kr == KERN_SUCCESS, let newInfo = newInfoRaw else {
            return CPUMetric.zero
        }

        guard let oldInfo = prevCpuInfo, numCores > 0 else {
            prevCpuInfo = newInfo
            prevNumCpuInfo = newCount
            numCores = newNumCores
            return CPUMetric.zero
        }

        let oldCores = numCores
        let oldElemCount = prevNumCpuInfo

        let coreCount = Int(min(newNumCores, oldCores))
        var perCore: [Double] = []
        perCore.reserveCapacity(coreCount)

        var totalUser: Double = 0
        var totalSystem: Double = 0
        var totalIdle: Double = 0
        var totalAll: Double = 0

        for i in 0..<coreCount {
            let newTicks = readCpuTicks(newInfo, index: i)
            let oldTicks = readCpuTicks(oldInfo, index: i)

            // 对齐活动监视器口径：nice（低优先级进程）时间计入 user
            let user = Double(max(0, newTicks.0 &- oldTicks.0)) + Double(max(0, newTicks.3 &- oldTicks.3))
            let system = Double(max(0, newTicks.1 &- oldTicks.1))
            let idle = Double(max(0, newTicks.2 &- oldTicks.2))

            let total = user + system + idle
            let usage = total > 0 ? (user + system) / total : 0
            perCore.append(usage)

            totalUser += user
            totalSystem += system
            totalIdle += idle
            totalAll += total
        }

        let deallocSize = vm_size_t(oldElemCount) * vm_size_t(MemoryLayout<Int32>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: oldInfo), deallocSize)

        prevCpuInfo = newInfo
        prevNumCpuInfo = newCount
        numCores = newNumCores

        let overallUsage = totalAll > 0 ? (totalUser + totalSystem) / totalAll : 0

        return CPUMetric(
            overallUsage: overallUsage,
            perCoreUsage: perCore,
            userUsage: totalAll > 0 ? totalUser / totalAll : 0,
            systemUsage: totalAll > 0 ? totalSystem / totalAll : 0,
            idleUsage: totalAll > 0 ? totalIdle / totalAll : 0
        )
    }

    private func readCpuTicks(_ info: processor_info_array_t, index: Int) -> (UInt32, UInt32, UInt32, UInt32) {
        let int32sPerStruct = MemoryLayout<processor_cpu_load_info>.stride / MemoryLayout<Int32>.stride
        let base = index * int32sPerStruct

        let user = UInt32(bitPattern: info[base])
        let system = UInt32(bitPattern: info[base + 1])
        let idle = UInt32(bitPattern: info[base + 2])
        let nice = UInt32(bitPattern: info[base + 3])

        return (user, system, idle, nice)
    }
}
