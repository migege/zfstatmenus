import Foundation
import Darwin

final class NetworkMonitor: Monitor {

    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastTime: Date = .distantPast
    private var hasPreviousSample = false

    func snapshot() -> Any {
        let (totalIn, totalOut) = readInterfaceBytes()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)

        if !hasPreviousSample {
            lastBytesIn = totalIn
            lastBytesOut = totalOut
            lastTime = now
            hasPreviousSample = true
            return NetworkMetric.zero
        }

        let deltaIn = totalIn > lastBytesIn ? Double(totalIn - lastBytesIn) : 0
        let deltaOut = totalOut > lastBytesOut ? Double(totalOut - lastBytesOut) : 0

        lastBytesIn = totalIn
        lastBytesOut = totalOut
        lastTime = now

        let downSpeed = elapsed > 0 ? deltaIn / elapsed : 0
        let upSpeed = elapsed > 0 ? deltaOut / elapsed : 0

        return NetworkMetric(
            downloadBytesPerSec: downSpeed,
            uploadBytesPerSec: upSpeed,
            totalDownload: totalIn,
            totalUpload: totalOut
        )
    }

    private func readInterfaceBytes() -> (inBytes: UInt64, outBytes: UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return (0, 0)
        }
        defer { freeifaddrs(firstAddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = cursor {
            let info = ifa.pointee
            guard let addrPtr = info.ifa_addr else {
                cursor = info.ifa_next
                continue
            }

            let family = addrPtr.pointee.sa_family
            if family == UInt8(AF_LINK) {
                let name = String(cString: info.ifa_name)
                if !name.hasPrefix("lo") {
                    let data = unsafeBitCast(info.ifa_data, to: UnsafeMutablePointer<if_data>.self)
                    totalIn += UInt64(data.pointee.ifi_ibytes)
                    totalOut += UInt64(data.pointee.ifi_obytes)
                }
            }
            cursor = info.ifa_next
        }

        return (totalIn, totalOut)
    }
}
