import SwiftUI

private struct PopoverPage<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    let content: Content

    init(
        width: CGFloat = AppTheme.tokenPopoverWidth,
        height: CGFloat = AppTheme.tokenPopoverHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.height = height
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(width: width - 40, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
        }
        .appPopoverScrolling()
        .frame(width: width, height: height)
        .background(AppTheme.canvas)
    }
}

// MARK: - CPU

struct CPUDetailView: View {
    @ObservedObject var holder: MonitorHolder

    init(monitorManager: MonitorManager) {
        self.holder = MonitorHolder(monitorManager: monitorManager)
    }

    var body: some View {
        PopoverPage(width: AppTheme.detailPopoverWidth, height: AppTheme.detailPopoverHeight) {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(
                    title: "CPU",
                    subtitle: "\(holder.cpu.perCoreUsage.count) 个逻辑核心",
                    systemImage: "cpu"
                )

                HStack(spacing: 12) {
                    DetailHeroMetric(
                        label: "总使用率",
                        value: String(format: "%.1f%%", holder.cpu.overallUsage * 100),
                        systemImage: "waveform.path.ecg"
                    )
                    DetailHeroMetric(
                        label: "用户",
                        value: String(format: "%.1f%%", holder.cpu.userUsage * 100),
                        systemImage: "person.fill"
                    )
                    DetailHeroMetric(
                        label: "系统",
                        value: String(format: "%.1f%%", holder.cpu.systemUsage * 100),
                        systemImage: "gearshape.2.fill"
                    )
                }

                if !holder.cpuHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeader(title: "最近一分钟", trailing: "总体使用率")
                        BarChartView(values: holder.cpuHistory, color: AppTheme.accent)
                            .frame(height: 68)
                    }
                    .appPanel(padding: 13)
                }

                if !holder.cpu.perCoreUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeader(title: "核心活动", trailing: "\(holder.cpu.perCoreUsage.count) 核")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                            ForEach(Array(holder.cpu.perCoreUsage.enumerated()), id: \.offset) { index, usage in
                                CoreActivityCell(index: index, usage: usage)
                            }
                        }
                    }
                    .appPanel(padding: 13)
                }

                if !holder.topCPU.isEmpty {
                    ProcessListPanel(title: "占用最高", processes: holder.topCPU) { process in
                        String(format: "%.1f%%", process.cpuUsage * 100)
                    }
                }
            }
        }
        .onAppear { holder.start(.cpu) }
        .onDisappear { holder.stop() }
    }
}

// MARK: - Memory

struct MemoryDetailView: View {
    @ObservedObject var holder: MonitorHolder

    init(monitorManager: MonitorManager) {
        self.holder = MonitorHolder(monitorManager: monitorManager)
    }

    var body: some View {
        PopoverPage(width: AppTheme.detailPopoverWidth, height: AppTheme.detailPopoverHeight) {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: "内存", subtitle: "物理内存与交换空间", systemImage: "memorychip")

                if holder.memory.total == 0 {
                    AppEmptyState(systemName: "memorychip", title: "正在读取内存", detail: "首次采样完成后将在这里显示使用情况。")
                        .appPanel()
                } else {
                    HStack(spacing: 18) {
                        MemoryUsageRing(
                            ratio: Double(holder.memory.used) / Double(holder.memory.total),
                            value: formatBytes(holder.memory.used)
                        )
                        VStack(spacing: 8) {
                            CompactMetric(label: "可用", value: formatBytes(holder.memory.free))
                            CompactMetric(label: "总计", value: formatBytes(holder.memory.total))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appPanel(padding: 14)

                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeader(title: "内存构成")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            MemoryBreakdownCell(label: "App 内存", value: formatBytes(holder.memory.appMemory))
                            MemoryBreakdownCell(label: "Wired", value: formatBytes(holder.memory.wired))
                            MemoryBreakdownCell(label: "压缩", value: formatBytes(holder.memory.compressed))
                            MemoryBreakdownCell(label: "缓存文件", value: formatBytes(holder.memory.cachedFiles))
                            if holder.memory.swapUsed > 0 {
                                MemoryBreakdownCell(label: "Swap", value: formatBytes(holder.memory.swapUsed))
                            }
                        }
                    }
                    .appPanel(padding: 13)

                    if !holder.topMemory.isEmpty {
                        ProcessListPanel(title: "占用最高", processes: holder.topMemory) {
                            formatBytes($0.memoryBytes)
                        }
                    }
                }
            }
        }
        .onAppear { holder.start(.memory) }
        .onDisappear { holder.stop() }
    }
}

// MARK: - Network

struct NetworkDetailView: View {
    @ObservedObject var holder: MonitorHolder

    init(monitorManager: MonitorManager) {
        self.holder = MonitorHolder(monitorManager: monitorManager)
    }

    var body: some View {
        PopoverPage(width: AppTheme.detailPopoverWidth, height: AppTheme.detailPopoverHeight) {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: "网络", subtitle: "实时吞吐与进程带宽", systemImage: "arrow.up.arrow.down")

                HStack(spacing: 10) {
                    NetworkHeroMetric(
                        title: "下载",
                        value: formatSpeed(holder.network.downloadBytesPerSec),
                        total: formatBytes(holder.network.totalDownload),
                        systemImage: "arrow.down"
                    )
                    NetworkHeroMetric(
                        title: "上传",
                        value: formatSpeed(holder.network.uploadBytesPerSec),
                        total: formatBytes(holder.network.totalUpload),
                        systemImage: "arrow.up"
                    )
                }

                if !holder.netDownHistory.isEmpty || !holder.netUpHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        AppSectionHeader(title: "最近一分钟", trailing: "实时速率")
                        if !holder.netDownHistory.isEmpty {
                            TrendRow(label: "下载", values: holder.netDownHistory, color: AppTheme.accent)
                        }
                        if !holder.netUpHistory.isEmpty {
                            TrendRow(label: "上传", values: holder.netUpHistory, color: AppTheme.accent.opacity(0.48))
                        }
                    }
                    .appPanel(padding: 13)
                }

                if !holder.topNetwork.isEmpty {
                    NetworkProcessListPanel(processes: holder.topNetwork)
                }
            }
        }
        .onAppear { holder.start(.network) }
        .onDisappear { holder.stop() }
    }
}

private struct DetailHeroMetric: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.accent)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .tracking(-0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .appPanel(padding: 13)
    }
}

private struct CompactMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CoreActivityCell: View {
    let index: Int
    let usage: Double

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(AppTheme.subtleFill)
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.accent.opacity(0.35 + min(max(usage, 0), 1) * 0.65))
                    .frame(height: max(2, 28 * CGFloat(usage)))
            }
            .frame(width: 7, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("C\(index + 1)").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", usage * 100))
                    .font(.system(size: 9, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(AppTheme.subtleFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MemoryUsageRing: View {
    let ratio: Double
    let value: String

    var body: some View {
        ZStack {
            Circle().stroke(AppTheme.subtleFill, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(ratio, 0), 1))
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(String(format: "%.0f%%", ratio * 100))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(value).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityLabel("内存使用率 \(String(format: "%.0f%%", ratio * 100))")
    }
}

private struct MemoryBreakdownCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct NetworkHeroMetric: View {
    let title: String
    let value: String
    let total: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("累计 \(total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(padding: 12)
    }
}

private struct TrendRow: View {
    let label: String
    let values: [Double]
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            BarChartView(values: values, color: color)
                .frame(height: 34)
        }
    }
}

private struct ProcessListPanel: View {
    let title: String
    let processes: [TopProcess]
    let value: (TopProcess) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AppSectionHeader(title: title, trailing: "Top \(processes.count)")
            VStack(spacing: 7) {
                ForEach(processes) { process in
                    ProcessRow(icon: process.icon, name: process.name, value: value(process), valueColor: AppTheme.accent)
                }
            }
        }
        .appPanel(padding: 12)
    }
}

private struct NetworkProcessListPanel: View {
    let processes: [NetworkProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AppSectionHeader(title: "带宽占用最高", trailing: "Top \(processes.count)")
            VStack(spacing: 8) {
                ForEach(processes) { process in
                    HStack(spacing: 8) {
                        ProcessIcon(icon: process.icon)
                        Text(process.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("↓ \(formatSpeed(Double(process.bytesIn)))")
                            Text("↑ \(formatSpeed(Double(process.bytesOut)))")
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .appPanel(padding: 12)
    }
}

// MARK: - Token

struct TokenDetailView: View {
    @ObservedObject var monitor: TokenUsageMonitor
    @ObservedObject private var syncService = TokenSyncService.shared
    @AppStorage("tokenDisplayCurrency") private var currency = "both"
    @AppStorage("tokenUSDToCNYRate") private var usdToCNYRate = 7.2

    var body: some View {
        PopoverPage {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image("TokenGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Token 活动")
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(-0.2)
                        Text("本机与已同步设备的综合统计")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        TokenSyncStatusSymbol(status: syncService.status)
                        Text(syncService.status.message)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .help(syncStatusHelp)
                    if monitor.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    AppIconButton(systemName: "arrow.clockwise", help: "刷新 Token 数据") {
                        monitor.refresh()
                    }
                    AppIconButton(systemName: "gearshape", help: "打开设置") {
                        AppWindowActions.openSettings()
                    }
                    AppIconButton(systemName: "power", help: "退出 ZFStatMenus") {
                        AppWindowActions.quit()
                    }
                }

                HStack(spacing: 10) {
                    TokenSummaryCard(
                        title: "今日",
                        value: monitor.snapshot.todayTokens,
                        cost: costText(last: 1),
                        dayCount: 1,
                        devices: monitor.deviceUsages
                    )
                    TokenSummaryCard(
                        title: "过去 7 天",
                        value: monitor.snapshot.last7DaysTokens,
                        cost: costText(last: 7),
                        dayCount: 7,
                        devices: monitor.deviceUsages
                    )
                    TokenSummaryCard(
                        title: "过去 30 天",
                        value: monitor.snapshot.last30DaysTokens,
                        cost: costText(last: 30),
                        dayCount: 30,
                        devices: monitor.deviceUsages
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    AppSectionHeader(title: "消耗热力图", subtitle: "悬停任意日期查看当天模型明细", trailing: "近一年")
                    TokenCalendarHeatmap(
                        days: monitor.snapshot.days,
                        currency: currency,
                        usdToCNYRate: usdToCNYRate
                    )
                }
                .appPanel(padding: 13)

                HStack(alignment: .top, spacing: 12) {
                    sourceSection(title: "今日来源", dayCount: 1)
                    sourceSection(title: "过去 30 天来源", dayCount: 30)
                }

                VStack(alignment: .leading, spacing: 8) {
                    AppSectionHeader(
                        title: "模型费用估算",
                        subtitle: "过去 30 天，按第一方公开 API 单价计算",
                        trailing: "已定价优先"
                    )

                    if recentModels.isEmpty {
                        AppEmptyState(
                            systemName: "chart.bar.xaxis",
                            title: "暂无可展示模型",
                            detail: "完成首次扫描后，这里会显示 Token 不少于 1K 的模型。"
                        )
                    } else {
                        VStack(spacing: 0) {
                            TokenCostColumnHeader(leftTitle: "模型", currency: currency)
                            Divider().overlay(AppTheme.border)
                            ForEach(Array(recentModels.enumerated()), id: \.element.id) { index, usage in
                                ModelTokenCostRow(
                                    usage: usage,
                                    currency: currency,
                                    usdToCNYRate: usdToCNYRate
                                )
                                if index < recentModels.count - 1 {
                                    Divider().padding(.leading, 12).overlay(AppTheme.border)
                                }
                            }
                        }
                        .background(AppTheme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: AppTheme.innerRadius))
                    }

                    let estimate = estimateAPICost(for: displayedModelsLast30Days)
                    if !estimate.unpricedModels.isEmpty {
                        Label(
                            "未定价模型：\(estimate.unpricedModels.sorted().joined(separator: "、"))",
                            systemImage: "questionmark.circle"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("估算使用公开标准 API 单价与设置中的汇率；不含订阅费、长上下文阶梯、Batch/Priority、工具调用及地区差异。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appPanel(padding: 13)

                if let error = monitor.snapshot.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sourceColor(_ source: TokenSource) -> Color {
        AppTheme.accent
    }

    private var syncStatusHelp: String {
        var values = [syncService.status.message]
        if syncService.status.pendingDays > 0 {
            values.append("待同步 \(syncService.status.pendingDays) 天")
        }
        if let date = syncService.status.lastSuccessAt {
            values.append("上次成功：\(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return values.joined(separator: " · ")
    }

    private func costText(last dayCount: Int) -> String {
        formatTokenCost(
            monitor.snapshot.apiCost(last: dayCount),
            currency: currency,
            usdToCNY: usdToCNYRate
        )
    }

    private var displayedModelsLast30Days: [ModelTokenUsage] {
        sortedModelUsagesForDisplay(
            monitor.snapshot.modelUsages(last: 30),
            usdToCNYRate: usdToCNYRate
        )
    }

    private var recentModels: [ModelTokenUsage] {
        Array(displayedModelsLast30Days.prefix(20))
    }

    private func sourceSection(title: String, dayCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeader(title: title, trailing: "≥ 1K")

            VStack(spacing: 0) {
                TokenCostColumnHeader(leftTitle: "来源", currency: currency)
                Divider().overlay(AppTheme.border)
                let sources = sortedTokenSourcesForDisplay(
                    monitor.snapshot,
                    last: dayCount,
                    usdToCNYRate: usdToCNYRate
                )
                if sources.isEmpty {
                    Text("暂无达到 1K Token 的来源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                        SourceTokenCostRow(
                            source: source,
                            color: sourceColor(source),
                            tokens: monitor.snapshot.totalTokens(for: source, last: dayCount),
                            estimate: monitor.snapshot.apiCost(for: source, last: dayCount),
                            currency: currency,
                            usdToCNYRate: usdToCNYRate
                        )
                        if index < sources.count - 1 {
                            Divider().padding(.leading, 12).overlay(AppTheme.border)
                        }
                    }
                }
            }
            .background(AppTheme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: AppTheme.innerRadius))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appPanel(padding: 12)
    }
}

private enum TokenListLayout {
    static let tokenWidth: CGFloat = 70
    static let usdWidth: CGFloat = 68
    static let cnyWidth: CGFloat = 78
    static let columnSpacing: CGFloat = 8
    static let currencySpacing: CGFloat = 8
    static let panelBackground = AppTheme.subtleFill

    static func costWidth(for currency: String) -> CGFloat {
        switch currency {
        case "usd": return usdWidth
        case "cny": return cnyWidth
        default: return usdWidth + currencySpacing + cnyWidth
        }
    }
}

let minimumDisplayedTokenCount: Int64 = 1_000

func sortedModelUsagesForDisplay(
    _ usages: [ModelTokenUsage],
    usdToCNYRate: Double
) -> [ModelTokenUsage] {
    usages.filter { $0.tokens.totalTokens >= minimumDisplayedTokenCount }.sorted { lhs, rhs in
        let lhsEstimate = estimateAPICost(for: [lhs])
        let rhsEstimate = estimateAPICost(for: [rhs])
        let lhsIsPriced = lhsEstimate.pricedTokens > 0
        let rhsIsPriced = rhsEstimate.pricedTokens > 0

        if lhsIsPriced != rhsIsPriced {
            return lhsIsPriced
        }
        let lhsCost = lhsEstimate.totalCNY(usdToCNY: usdToCNYRate)
        let rhsCost = rhsEstimate.totalCNY(usdToCNY: usdToCNYRate)
        if lhsCost != rhsCost {
            return lhsCost > rhsCost
        }
        if lhs.tokens.totalTokens != rhs.tokens.totalTokens {
            return lhs.tokens.totalTokens > rhs.tokens.totalTokens
        }
        return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
    }
}

func sortedTokenSourcesForDisplay(
    _ snapshot: TokenUsageSnapshot,
    last dayCount: Int,
    usdToCNYRate: Double
) -> [TokenSource] {
    TokenSource.allCases.filter {
        snapshot.totalTokens(for: $0, last: dayCount) >= minimumDisplayedTokenCount
    }.sorted { lhs, rhs in
        let lhsEstimate = snapshot.apiCost(for: lhs, last: dayCount)
        let rhsEstimate = snapshot.apiCost(for: rhs, last: dayCount)
        let lhsIsPriced = lhsEstimate.pricedTokens > 0
        let rhsIsPriced = rhsEstimate.pricedTokens > 0

        if lhsIsPriced != rhsIsPriced {
            return lhsIsPriced
        }
        let lhsCost = lhsEstimate.totalCNY(usdToCNY: usdToCNYRate)
        let rhsCost = rhsEstimate.totalCNY(usdToCNY: usdToCNYRate)
        if lhsCost != rhsCost {
            return lhsCost > rhsCost
        }
        let lhsTokens = snapshot.totalTokens(for: lhs, last: dayCount)
        let rhsTokens = snapshot.totalTokens(for: rhs, last: dayCount)
        if lhsTokens != rhsTokens {
            return lhsTokens > rhsTokens
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private struct TokenCostColumnHeader: View {
    let leftTitle: String
    let currency: String

    var body: some View {
        HStack(spacing: TokenListLayout.columnSpacing) {
            Text(leftTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("TOKEN")
                .frame(width: TokenListLayout.tokenWidth, alignment: .trailing)
            TokenCurrencyHeader(currency: currency)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct TokenCurrencyHeader: View {
    let currency: String

    var body: some View {
        HStack(spacing: currency == "both" ? TokenListLayout.currencySpacing : 0) {
            if currency != "cny" {
                Text("USD")
                    .frame(width: TokenListLayout.usdWidth, alignment: .trailing)
            }
            if currency != "usd" {
                Text("CNY")
                    .frame(width: TokenListLayout.cnyWidth, alignment: .trailing)
            }
        }
        .frame(width: TokenListLayout.costWidth(for: currency), alignment: .trailing)
    }
}

private struct TokenCostColumns: View {
    let estimate: TokenCostEstimate
    let currency: String
    let usdToCNYRate: Double

    var body: some View {
        Group {
            if estimate.pricedTokens > 0 {
                HStack(spacing: currency == "both" ? TokenListLayout.currencySpacing : 0) {
                    if currency != "cny" {
                        Text(formatTokenCostUSD(estimate, usdToCNY: usdToCNYRate))
                            .frame(width: TokenListLayout.usdWidth, alignment: .trailing)
                    }
                    if currency != "usd" {
                        Text(formatTokenCostCNY(estimate, usdToCNY: usdToCNYRate))
                            .frame(width: TokenListLayout.cnyWidth, alignment: .trailing)
                    }
                }
            } else {
                Text("未定价")
                    .frame(width: TokenListLayout.costWidth(for: currency), alignment: .trailing)
            }
        }
        .font(.system(.body, design: .monospaced))
        .frame(width: TokenListLayout.costWidth(for: currency), alignment: .trailing)
    }
}

private struct SourceTokenCostRow: View {
    let source: TokenSource
    let color: Color
    let tokens: Int64
    let estimate: TokenCostEstimate
    let currency: String
    let usdToCNYRate: Double

    var body: some View {
        HStack(spacing: TokenListLayout.columnSpacing) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(source.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatTokenCount(tokens))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: TokenListLayout.tokenWidth, alignment: .trailing)

            TokenCostColumns(
                estimate: estimate,
                currency: currency,
                usdToCNYRate: usdToCNYRate
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct TokenSummaryCard: View {
    let title: String
    let value: Int64
    let cost: String
    let dayCount: Int
    let devices: [DeviceTokenUsageSummary]

    private var sortedDevices: [DeviceTokenUsageSummary] {
        devices.sorted {
            let lhsTokens = $0.totalTokens(last: dayCount)
            let rhsTokens = $1.totalTokens(last: dayCount)
            if lhsTokens == rhsTokens {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return lhsTokens > rhsTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.accent)
                    .frame(width: 18, height: 3)
            }
            Text(formatTokenCount(value))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .tracking(-0.35)
                .monospacedDigit()
            Text(cost)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if !sortedDevices.isEmpty {
                Divider()
                    .overlay(AppTheme.border)
                    .padding(.vertical, 2)
                VStack(spacing: 2) {
                    ForEach(sortedDevices) { device in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(AppTheme.accent.opacity(device.isCurrentDevice ? 1 : 0.45))
                                .frame(width: 4, height: 4)
                            Text(device.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(formatTokenCount(device.totalTokens(last: dayCount)))
                                .monospacedDigit()
                                .layoutPriority(1)
                        }
                        .help("\(device.displayName)：\(formatTokenCount(device.totalTokens(last: dayCount))) Token")
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(padding: 12)
    }
}

private struct ModelTokenCostRow: View {
    let usage: ModelTokenUsage
    let currency: String
    let usdToCNYRate: Double
    @State private var isHovered = false

    private var estimate: TokenCostEstimate {
        estimateAPICost(for: [usage])
    }

    var body: some View {
        HStack(spacing: TokenListLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(usage.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(.medium)
                Text("\(usage.source.displayName) · \(usage.provider)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text(formatTokenCount(usage.tokens.totalTokens))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: TokenListLayout.tokenWidth, alignment: .trailing)

            TokenCostColumns(
                estimate: estimate,
                currency: currency,
                usdToCNYRate: usdToCNYRate
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovered ? AppTheme.accentSoft.opacity(0.55) : Color.clear)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
        .help("输入 \(formatTokenCount(usage.tokens.input)) · 缓存读取 \(formatTokenCount(usage.tokens.cachedInput)) · 缓存写入 \(formatTokenCount(usage.tokens.cacheWrite)) · 输出/推理 \(formatTokenCount(usage.tokens.output + usage.tokens.reasoning))")
    }
}

private struct TokenCalendarHeatmap: View {
    let days: [DailyTokenUsage]
    let currency: String
    let usdToCNYRate: Double
    @State private var hoverState = TokenHeatmapHoverState()

    private var weeks: [[DailyTokenUsage?]] {
        guard let first = days.first else { return [] }
        let leadingEmpty = Calendar.current.component(.weekday, from: first.date) - 1
        var cells = Array(repeating: Optional<DailyTokenUsage>.none, count: leadingEmpty)
        cells.append(contentsOf: days.map(Optional.some))
        while !cells.count.isMultiple(of: 7) { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let spacing: CGFloat = 3
                let cellSize = heatmapCellSize(
                    availableWidth: geometry.size.width,
                    weekCount: weeks.count,
                    spacing: spacing
                )

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(weeks.indices, id: \.self) { weekIndex in
                        VStack(spacing: spacing) {
                            ForEach(weeks[weekIndex].indices, id: \.self) { dayIndex in
                                heatmapCell(weeks[weekIndex][dayIndex], size: cellSize)
                            }
                        }
                    }
                }
            }
            .frame(height: 98)

            HStack(spacing: 4) {
                Spacer()
                Text("少").foregroundColor(.secondary)
                ForEach(0..<4) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(level: level))
                        .overlay {
                            if level == 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.gray.opacity(0.32), lineWidth: 0.7)
                            }
                        }
                        .frame(width: 11, height: 11)
                }
                Text("多").foregroundColor(.secondary)
            }
            .font(.caption2)

            Group {
                if let selectedDay = hoverState.day ?? days.last {
                    HeatmapHoverDetail(
                        day: selectedDay,
                        currency: currency,
                        usdToCNYRate: usdToCNYRate
                    )
                } else {
                Text("暂无 Token 数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func heatmapCell(_ day: DailyTokenUsage?, size: CGFloat) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: max(2, size * 0.22))
                .fill(heatColor(for: day.totalTokens))
                .overlay {
                    if day.totalTokens == 0 {
                        RoundedRectangle(cornerRadius: max(2, size * 0.22))
                            .stroke(Color.gray.opacity(0.32), lineWidth: 0.7)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .onHover { isHovered in
                    hoverState.update(day: day, isHovered: isHovered)
                }
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private func heatmapCellSize(
        availableWidth: CGFloat,
        weekCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        guard weekCount > 0 else { return 0 }
        let totalSpacing = CGFloat(max(weekCount - 1, 0)) * spacing
        return max(8, (availableWidth - totalSpacing) / CGFloat(weekCount))
    }

    private func heatColor(for tokenCount: Int64) -> Color {
        heatColor(level: tokenHeatLevel(tokenCount))
    }

    private func heatColor(level: Int) -> Color {
        switch level {
        case 1: return AppTheme.accent.opacity(0.28)
        case 2: return AppTheme.accent.opacity(0.62)
        case 3: return AppTheme.accent
        default: return AppTheme.elevatedSurface
        }
    }

}

struct TokenHeatmapHoverState: Equatable {
    private(set) var day: DailyTokenUsage?

    mutating func update(day candidate: DailyTokenUsage, isHovered: Bool) {
        if isHovered {
            day = candidate
        } else if day?.id == candidate.id {
            day = nil
        }
    }
}

private struct HeatmapHoverDetail: View {
    let day: DailyTokenUsage
    let currency: String
    let usdToCNYRate: Double

    private var modelUsages: [ModelTokenUsage] {
        sortedModelUsagesForDisplay(
            day.modelUsages,
            usdToCNYRate: usdToCNYRate
        )
    }

    private var totalEstimate: TokenCostEstimate {
        estimateAPICost(for: day.modelUsages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(formattedDate(day.date))
                        .fontWeight(.semibold)
                    Text("悬停日期查看当日模型")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatTokenCount(day.totalTokens))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: TokenListLayout.tokenWidth, alignment: .trailing)

                TokenCostColumns(
                    estimate: totalEstimate,
                    currency: currency,
                    usdToCNYRate: usdToCNYRate
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if modelUsages.isEmpty {
                Text("当日无模型消耗")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ForEach(Array(modelUsages.prefix(5))) { usage in
                    HeatmapModelCostRow(
                        usage: usage,
                        currency: currency,
                        usdToCNYRate: usdToCNYRate
                    )
                }

                if modelUsages.count > 5 {
                    Text("另有 \(modelUsages.count - 5) 个模型")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }
}

private struct HeatmapModelCostRow: View {
    let usage: ModelTokenUsage
    let currency: String
    let usdToCNYRate: Double

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(sourceColor)
                    .frame(width: 6, height: 6)
                Text(usage.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(usage.source.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text(formatTokenCount(usage.tokens.totalTokens))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: TokenListLayout.tokenWidth, alignment: .trailing)

            TokenCostColumns(
                estimate: estimateAPICost(for: [usage]),
                currency: currency,
                usdToCNYRate: usdToCNYRate
            )
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help("\(usage.source.displayName) · \(usage.provider)")
    }

    private var sourceColor: Color {
        AppTheme.accent
    }
}

// MARK: - Shared Components

struct DetailHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34, height: 34)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            AppIconButton(systemName: "gearshape", help: "打开设置") {
                AppWindowActions.openSettings()
            }
            AppIconButton(systemName: "power", help: "退出 ZFStatMenus") {
                AppWindowActions.quit()
            }
        }
    }
}

struct ProcessRow: View {
    let icon: NSImage?
    let name: String
    let value: String
    let valueColor: Color

    var body: some View {
        HStack(spacing: 8) {
            ProcessIcon(icon: icon)
            Text(name)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }
}

struct ProcessIcon: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.subtleFill)
                    .overlay {
                        Image(systemName: "app")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct BarChartView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.isEmpty {
                Text("无数据").foregroundColor(.secondary)
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let maxVal = max(values.max() ?? 1, 0.001)
                let barWidth = max(1, (geo.size.width - CGFloat(values.count - 1)) / CGFloat(values.count))
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, val in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color.opacity(0.28 + 0.72 * (val / maxVal)))
                            .frame(width: barWidth, height: max(1, geo.size.height * (val / maxVal)))
                    }
                }
            }
        }
    }
}

// MARK: - MonitorHolder

final class MonitorHolder: ObservableObject {
    @Published var cpu: CPUMetric = .zero
    @Published var memory: MemoryMetric = .zero
    @Published var network: NetworkMetric = .zero
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var netDownHistory: [Double] = []
    @Published var netUpHistory: [Double] = []
    @Published var topCPU: [TopProcess] = []
    @Published var topMemory: [TopProcess] = []
    @Published var topNetwork: [NetworkProcess] = []

    private let monitorManager: MonitorManager
    private var timer: Timer?
    private var observingType: StatusItemType?

    init(monitorManager: MonitorManager) {
        self.monitorManager = monitorManager
    }

    func start(_ type: StatusItemType) {
        observingType = type

        switch type {
        case .cpu:
            cpu = monitorManager.latestCPU
            cpuHistory = monitorManager.cpuHistory
            topCPU = monitorManager.processMonitor.topCPU()
        case .memory:
            memory = monitorManager.latestMemory
            memHistory = monitorManager.memUsedHistory
            topMemory = monitorManager.processMonitor.topMemory()
        case .network:
            network = monitorManager.latestNetwork
            netDownHistory = monitorManager.netDownHistory
            netUpHistory = monitorManager.netUpHistory
            topNetwork = monitorManager.processMonitor.topNetwork()
        case .token:
            break
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observingType = nil
    }

    private func refresh() {
        guard let type = observingType else { return }
        switch type {
        case .cpu:
            cpu = monitorManager.latestCPU
            cpuHistory = monitorManager.cpuHistory
            topCPU = monitorManager.processMonitor.topCPU()
        case .memory:
            memory = monitorManager.latestMemory
            memHistory = monitorManager.memUsedHistory
            topMemory = monitorManager.processMonitor.topMemory()
        case .network:
            network = monitorManager.latestNetwork
            netDownHistory = monitorManager.netDownHistory
            netUpHistory = monitorManager.netUpHistory
            topNetwork = monitorManager.processMonitor.topNetwork()
        case .token:
            break
        }
    }
}

// MARK: - Format helpers

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1_048_576 {
        return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
    } else if bytesPerSec >= 1024 {
        return String(format: "%.1f KB/s", bytesPerSec / 1024)
    } else {
        return String(format: "%.0f B/s", bytesPerSec)
    }
}
