import Foundation

protocol Monitor: AnyObject {
    func snapshot() -> Any
}

enum SystemSnapshot {
    case cpu(CPUMetric)
    case memory(MemoryMetric)
    case network(NetworkMetric)
}
