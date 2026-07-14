import Foundation

final class MonitorManager {

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let networkMonitor = NetworkMonitor()
    let processMonitor = ProcessMonitor()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.zfstat.monitor", qos: .utility)

    var onCPUUpdate: ((CPUMetric) -> Void)?
    var onMemoryUpdate: ((MemoryMetric) -> Void)?
    var onNetworkUpdate: ((NetworkMetric) -> Void)?

    private(set) var latestCPU: CPUMetric = .zero
    private(set) var latestMemory: MemoryMetric = .zero
    private(set) var latestNetwork: NetworkMetric = .zero

    // 滚动历史缓冲（最近 120 个采样点）
    private let maxHistory = 120
    private(set) var cpuHistory: [Double] = []
    private(set) var memUsedHistory: [Double] = []
    private(set) var memRatioHistory: [Double] = []
    private(set) var netDownHistory: [Double] = []
    private(set) var netUpHistory: [Double] = []

    func start(interval: TimeInterval = 1.0) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
        processMonitor.start()
        AppLog.monitor.info("MonitorManager started, interval=\(interval)s")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        processMonitor.stop()
    }

    func updateInterval(_ interval: TimeInterval) {
        start(interval: interval)
    }

    private func sample() {
        if let cpu = cpuMonitor.snapshot() as? CPUMetric {
            latestCPU = cpu
            DispatchQueue.main.async { [weak self] in
                self?.onCPUUpdate?(cpu)
                self?.pushCPUHistory(cpu.overallUsage)
            }
        }

        if let mem = memoryMonitor.snapshot() as? MemoryMetric {
            latestMemory = mem
            DispatchQueue.main.async { [weak self] in
                self?.onMemoryUpdate?(mem)
                self?.pushMemHistory(Double(mem.used), ratio: mem.usageRatio)
            }
        }

        if let net = networkMonitor.snapshot() as? NetworkMetric {
            latestNetwork = net
            DispatchQueue.main.async { [weak self] in
                self?.onNetworkUpdate?(net)
                self?.pushNetHistory(down: net.downloadBytesPerSec, up: net.uploadBytesPerSec)
            }
        }
    }

    // MARK: - History buffers (main thread)

    private func pushCPUHistory(_ value: Double) {
        cpuHistory.append(value)
        if cpuHistory.count > maxHistory { cpuHistory.removeFirst() }
    }

    private func pushMemHistory(_ used: Double, ratio: Double) {
        memUsedHistory.append(used)
        memRatioHistory.append(ratio)
        if memUsedHistory.count > maxHistory { memUsedHistory.removeFirst() }
        if memRatioHistory.count > maxHistory { memRatioHistory.removeFirst() }
    }

    private func pushNetHistory(down: Double, up: Double) {
        netDownHistory.append(down)
        netUpHistory.append(up)
        if netDownHistory.count > maxHistory { netDownHistory.removeFirst() }
        if netUpHistory.count > maxHistory { netUpHistory.removeFirst() }
    }
}
