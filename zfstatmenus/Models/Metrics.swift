import Foundation

struct CPUMetric: Equatable {
    var overallUsage: Double
    var perCoreUsage: [Double]
    var userUsage: Double
    var systemUsage: Double
    var idleUsage: Double

    static let zero = CPUMetric(
        overallUsage: 0, perCoreUsage: [], userUsage: 0, systemUsage: 0, idleUsage: 0
    )
}

struct MemoryMetric: Equatable {
    var total: UInt64
    var used: UInt64
    var free: UInt64
    var wired: UInt64
    var compressed: UInt64
    var appMemory: UInt64
    var cachedFiles: UInt64
    var swapUsed: UInt64

    var usageRatio: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    static let zero = MemoryMetric(
        total: 0, used: 0, free: 0, wired: 0, compressed: 0, appMemory: 0, cachedFiles: 0, swapUsed: 0
    )
}

struct NetworkMetric: Equatable {
    var downloadBytesPerSec: Double
    var uploadBytesPerSec: Double
    var totalDownload: UInt64
    var totalUpload: UInt64

    static let zero = NetworkMetric(
        downloadBytesPerSec: 0, uploadBytesPerSec: 0, totalDownload: 0, totalUpload: 0
    )
}

enum StatusItemType: String, CaseIterable, Codable {
    case cpu
    case memory
    case network
    case token

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .token: return "Token"
        }
    }

    var defaultColor: String {
        switch self {
        case .cpu: return "#4A9EFF"
        case .memory: return "#FF6B6B"
        case .network: return "#51CF66"
        case .token: return "#FFD43B"
        }
    }
}
