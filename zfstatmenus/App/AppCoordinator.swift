import AppKit
import Combine

final class AppCoordinator {

    private let monitorManager = MonitorManager()
    private let tokenUsageMonitor = TokenUsageMonitor()
    private lazy var statusBarController = StatusBarController(
        monitorManager: monitorManager,
        tokenUsageMonitor: tokenUsageMonitor
    )
    private let prefs = AppPreferences.shared

    func start() {
        monitorManager.onCPUUpdate = { [weak self] metric in
            self?.statusBarController.updateCPU(metric)
        }
        monitorManager.onMemoryUpdate = { [weak self] metric in
            self?.statusBarController.updateMemory(metric)
        }
        monitorManager.onNetworkUpdate = { [weak self] metric in
            self?.statusBarController.updateNetwork(metric)
        }
        tokenUsageMonitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.statusBarController.updateToken(snapshot)
            }
            .store(in: &subscriptions)
        statusBarController.setup()
        monitorManager.start(interval: prefs.monitorInterval)
        tokenUsageMonitor.start(interval: prefs.tokenRefreshInterval)

        AppLog.general.info("AppCoordinator started")
    }

    func stop() {
        monitorManager.stop()
        tokenUsageMonitor.stop()
    }

    private var subscriptions: Set<AnyCancellable> = []

}
