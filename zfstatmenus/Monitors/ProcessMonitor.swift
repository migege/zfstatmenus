import Foundation
import AppKit

struct TopProcess: Identifiable {
    let id = UUID()
    let pid: Int32
    let name: String
    let cpuUsage: Double
    let memoryBytes: UInt64
    let icon: NSImage?
}

struct NetworkProcess: Identifiable {
    let id = UUID()
    let pid: Int32
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let icon: NSImage?
}

final class ProcessMonitor {

    private(set) var cachedTopCPU: [TopProcess] = []
    private(set) var cachedTopMemory: [TopProcess] = []
    private(set) var cachedTopNetwork: [NetworkProcess] = []

    private var cpuMemTimer: DispatchSourceTimer?
    private var netTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.zfstat.procmon", qos: .utility)
    private var iconCache: [Int32: NSImage] = [:]

    func start() {
        stop()

        let t1 = DispatchSource.makeTimerSource(queue: queue)
        t1.schedule(deadline: .now() + 1, repeating: 3.0)
        t1.setEventHandler { [weak self] in self?.sampleCPUMem() }
        t1.resume()
        cpuMemTimer = t1

        let t2 = DispatchSource.makeTimerSource(queue: queue)
        t2.schedule(deadline: .now() + 2, repeating: 5.0)
        t2.setEventHandler { [weak self] in self?.sampleNetwork() }
        t2.resume()
        netTimer = t2
    }

    func stop() {
        cpuMemTimer?.cancel()
        cpuMemTimer = nil
        netTimer?.cancel()
        netTimer = nil
    }

    func topCPU() -> [TopProcess] { cachedTopCPU }
    func topMemory() -> [TopProcess] { cachedTopMemory }
    func topNetwork() -> [NetworkProcess] { cachedTopNetwork }

    // MARK: - CPU + Memory via top

    private func sampleCPUMem() {
        guard let output = runCommand("/usr/bin/top",
                                      args: ["-l", "2", "-n", "20", "-o", "cpu", "-stats", "pid,command,cpu,mem"]) else { return }

        // top -l 2 输出两轮，第二轮是 1 秒内的 delta
        // 找到第二轮的进程列表
        let lines = output.components(separatedBy: "\n")
        var pidHeaderCount = 0
        var processStart = -1

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("PID") {
                pidHeaderCount += 1
                if pidHeaderCount == 2 {
                    processStart = i + 1
                    break
                }
            }
        }

        guard processStart >= 0 else { return }

        struct ParsedProc {
            let pid: Int32
            let name: String
            let cpu: Double
            let memBytes: UInt64
        }

        var procs: [ParsedProc] = []

        for i in processStart..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }

            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4,
                  let pid = Int32(cols[0]) else { continue }

            // 从右往左：最后是 MEM，倒数第二是 CPU，中间是 command
            let memStr = String(cols[cols.count - 1])
            let cpuStr = String(cols[cols.count - 2])
            let name = cols[1..<(cols.count - 2)].joined(separator: " ")

            let cpu = Double(cpuStr) ?? 0.0
            let memBytes = parseMemString(memStr)

            procs.append(ParsedProc(pid: pid, name: name, cpu: cpu, memBytes: memBytes))
        }

        guard !procs.isEmpty else { return }

        let cpuTop = procs
            .filter { $0.cpu > 0 }
            .sorted { $0.cpu > $1.cpu }
            .prefix(5)
            .map { TopProcess(pid: $0.pid, name: $0.name, cpuUsage: $0.cpu / 100.0, memoryBytes: $0.memBytes, icon: appIcon(for: $0.pid)) }

        let memTop = procs
            .sorted { $0.memBytes > $1.memBytes }
            .prefix(5)
            .map { TopProcess(pid: $0.pid, name: $0.name, cpuUsage: 0, memoryBytes: $0.memBytes, icon: appIcon(for: $0.pid)) }

        DispatchQueue.main.async { [weak self] in
            self?.cachedTopCPU = cpuTop
            self?.cachedTopMemory = memTop
        }
    }

    // top 输出内存格式: "1133M+", "4688K+", "2G-", "360M"
    private func parseMemString(_ s: String) -> UInt64 {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let numStr = String(String.UnicodeScalarView(digits))
        guard let num = Double(numStr) else { return 0 }

        if trimmed.contains("G") {
            return UInt64(num * 1024 * 1024 * 1024)
        } else if trimmed.contains("M") {
            return UInt64(num * 1024 * 1024)
        } else if trimmed.contains("K") {
            return UInt64(num * 1024)
        }
        return UInt64(num)
    }

    // MARK: - Network via nettop

    private func sampleNetwork() {
        guard let output = runCommand("/usr/bin/nettop",
                                      args: ["-P", "-d", "-L", "2", "-J", "bytes_in,bytes_out", "-x"]) else { return }

        // 输出为两轮采样，每轮以表头行 ",bytes_in,bytes_out," 开头（轮之间无空行）；
        // -d 模式下第二轮是相邻采样间（约 1 秒）的增量，可直接当作 bytes/s
        let lines = output.components(separatedBy: "\n")
        var headerCount = 0
        var deltaStart = -1
        for (i, line) in lines.enumerated() {
            if line.hasPrefix(",bytes_in") {
                headerCount += 1
                if headerCount == 2 {
                    deltaStart = i + 1
                    break
                }
            }
        }
        guard deltaStart >= 0 else { return }

        var results: [(pid: Int32, name: String, bytesIn: UInt64, bytesOut: UInt64)] = []

        for line in lines[deltaStart...] {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }

            // 进程列格式为 name.pid，进程名本身可能含点号，取最后一个点号后的 pid
            let namePid = String(cols[0])
            guard let lastDot = namePid.lastIndex(of: ".") else { continue }
            let name = String(namePid[..<lastDot])
            let pidStr = String(namePid[namePid.index(after: lastDot)...])
            guard let pid = Int32(pidStr) else { continue }

            let bytesIn = UInt64(cols[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let bytesOut = UInt64(cols[2].trimmingCharacters(in: .whitespaces)) ?? 0

            if bytesIn > 0 || bytesOut > 0 {
                results.append((pid, name, bytesIn, bytesOut))
            }
        }

        let netTop = results
            .sorted { ($0.bytesIn + $0.bytesOut) > ($1.bytesIn + $1.bytesOut) }
            .prefix(5)
            .map { NetworkProcess(pid: $0.pid, name: $0.name, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, icon: appIcon(for: $0.pid)) }

        DispatchQueue.main.async { [weak self] in
            self?.cachedTopNetwork = netTop
        }
    }

    // MARK: - Helpers

    private func runCommand(_ path: String, args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }

    private func appIcon(for pid: Int32) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let icon = app?.icon
        if let icon = icon {
            iconCache[pid] = icon
        }
        return icon
    }
}
