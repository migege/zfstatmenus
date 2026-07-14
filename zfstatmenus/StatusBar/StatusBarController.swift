import AppKit
import SwiftUI

final class StatusBarController: NSObject {

    private var statusItems: [StatusItemType: NSStatusItem] = [:]
    private var itemViews: [StatusItemType: StatusItemView] = [:]
    private var popovers: [StatusItemType: NSPopover] = [:]

    private var activePopoverType: StatusItemType?
    private var outsideClickMonitor: Any?

    private let monitorManager: MonitorManager
    private let tokenUsageMonitor: TokenUsageMonitor
    private let prefs = AppPreferences.shared

    init(monitorManager: MonitorManager, tokenUsageMonitor: TokenUsageMonitor) {
        self.monitorManager = monitorManager
        self.tokenUsageMonitor = tokenUsageMonitor
    }

    func setup() {
        configureItems()
    }

    func configureItems() {
        let enabled = prefs.enabledStatusItems
        let order = prefs.statusItemOrder

        AppLog.general.info("[StatusBar] enabled=\(enabled.map(\.rawValue)), order=\(order.map(\.rawValue))")

        for type in StatusItemType.allCases {
            if !enabled.contains(type) {
                removeItem(type)
            }
        }

        for type in order where enabled.contains(type) {
            ensureItem(type)
        }
    }

    private func itemWidth(for type: StatusItemType) -> CGFloat {
        switch type {
        case .cpu: return 86
        case .memory: return 76
        case .network: return 76
        case .token: return 64
        }
    }

    private func ensureItem(_ type: StatusItemType) {
        guard statusItems[type] == nil else { return }

        let width = itemWidth(for: type)
        let item = NSStatusBar.system.statusItem(withLength: width)
        statusItems[type] = item

        let view = StatusItemView(type: type)
        itemViews[type] = view

        // 分级宽度：内容增长时按档位跳档，回落时也按档位缩回
        view.onWidthChange = { [weak self, weak item] needed in
            guard let item = item else { return }
            let tiers: [CGFloat]
            if type == .network {
                tiers = [68, 76, 84, 92, 104]
            } else if type == .token {
                tiers = [56, 64, 72, 80]
            } else {
                tiers = [80, 92, 100, 110]
            }
            let newLength = tiers.first { needed <= $0 } ?? tiers.last!
            if abs(item.length - newLength) > 0.5 {
                item.length = newLength
                self?.itemViews[type]?.needsDisplay = true
            }
        }

        guard let button = item.button else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor, constant: 1.5),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1.5),
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 400)
        popovers[type] = popover

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func removeItem(_ type: StatusItemType) {
        if let item = statusItems[type] {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItems.removeValue(forKey: type)
        itemViews.removeValue(forKey: type)
        popovers.removeValue(forKey: type)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let type = identifyType(from: sender) else { return }
        if activePopoverType == type, popovers[type]?.isShown == true {
            closeActivePopover()
        } else {
            showPopover(for: type, sender: sender)
        }
    }

    private func identifyType(from button: NSStatusBarButton) -> StatusItemType? {
        for (type, item) in statusItems {
            if item.button === button {
                return type
            }
        }
        return nil
    }

    private func showPopover(for type: StatusItemType, sender: NSStatusBarButton) {
        closeActivePopover()
        guard let popover = popovers[type] else { return }

        let hostingView: NSView

        switch type {
        case .cpu:
            hostingView = NSHostingView(rootView: CPUDetailView(monitorManager: monitorManager))
        case .memory:
            hostingView = NSHostingView(rootView: MemoryDetailView(monitorManager: monitorManager))
        case .network:
            hostingView = NSHostingView(rootView: NetworkDetailView(monitorManager: monitorManager))
        case .token:
            hostingView = NSHostingView(rootView: TokenDetailView(monitor: tokenUsageMonitor))
        }

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        switch type {
        case .cpu, .memory, .network:
            popover.contentSize = NSSize(
                width: AppTheme.detailPopoverWidth,
                height: AppTheme.detailPopoverHeight
            )
        case .token:
            popover.contentSize = NSSize(
                width: AppTheme.tokenPopoverWidth,
                height: AppTheme.tokenPopoverHeight
            )
        }

        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = hostingView

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        activePopoverType = type
        startOutsideClickMonitor()
    }

    private func closeActivePopover() {
        guard let type = activePopoverType else { return }
        popovers[type]?.performClose(nil)
        activePopoverType = nil
        stopOutsideClickMonitor()
    }

    // accessory 应用点击其他 App/桌面时事件不进入本进程，transient 不可靠，
    // 需要全局监听在弹窗外的鼠标按下事件来主动收起
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeActivePopover()
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Update methods

    func updateCPU(_ metric: CPUMetric) {
        guard let view = itemViews[.cpu] else { return }
        view.updateCPU(perCore: metric.perCoreUsage, overall: metric.overallUsage)
    }

    func updateMemory(_ metric: MemoryMetric) {
        guard let view = itemViews[.memory] else { return }
        view.updateMemory(ratio: metric.usageRatio, text: formatMemShort(metric.used))
    }

    func updateNetwork(_ metric: NetworkMetric) {
        guard let view = itemViews[.network] else { return }
        view.updateNetwork(down: formatSpeedShort(metric.downloadBytesPerSec), up: formatSpeedShort(metric.uploadBytesPerSec))
    }

    func updateToken(_ snapshot: TokenUsageSnapshot) {
        itemViews[.token]?.updateToken(today: snapshot.todayTokens)
    }

    private func formatMemShort(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1fG", gb)
        } else {
            return String(format: "%.0fM", Double(bytes) / 1_048_576)
        }
    }

    private func formatSpeedShort(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        } else {
            return String(format: "%.0f KB/s", bytesPerSec / 1024)
        }
    }
}

extension StatusBarController: NSPopoverDelegate {

    // transient 行为自行关闭（如 Esc）时也要清理监听器和状态；
    // 只在关闭的是当前活跃弹窗时清理，避免切换面板时旧弹窗的异步关闭误清新状态
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover,
              let type = activePopoverType,
              popovers[type] === closed else { return }
        activePopoverType = nil
        stopOutsideClickMonitor()
    }
}
