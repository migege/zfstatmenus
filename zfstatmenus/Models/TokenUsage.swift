import Foundation

enum TokenSource: String, CaseIterable, Codable, Hashable {
    case opencode
    case zcode
    case codex
    case claude

    var displayName: String {
        switch self {
        case .opencode: return "OpenCode"
        case .zcode: return "ZCode"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

struct TokenBreakdown: Codable, Equatable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    var totalTokens: Int64 {
        input + cachedInput + cacheWrite + output + reasoning
    }

    static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) {
        lhs = lhs + rhs
    }
}

struct ModelTokenUsage: Codable, Equatable, Identifiable {
    let source: TokenSource
    let provider: String
    let model: String
    var tokens: TokenBreakdown

    var id: String { "\(source.rawValue)|\(provider.lowercased())|\(model.lowercased())" }
    var displayName: String { model.isEmpty ? "未知模型" : model }
}

struct DailyTokenUsage: Identifiable, Equatable {
    let date: Date
    let modelUsages: [ModelTokenUsage]

    init(date: Date, modelUsages: [ModelTokenUsage]) {
        self.date = date
        self.modelUsages = modelUsages
    }

    // 保留给简单测试和预览使用；真实采集数据始终带模型与 Token 分类。
    init(date: Date, sourceTotals: [TokenSource: Int64]) {
        self.date = date
        self.modelUsages = sourceTotals.map { source, total in
            ModelTokenUsage(
                source: source,
                provider: "legacy",
                model: "未分类",
                tokens: TokenBreakdown(input: total)
            )
        }
    }

    var id: Date { date }
    var totalTokens: Int64 { modelUsages.reduce(0) { $0 + $1.tokens.totalTokens } }
    var sourceTotals: [TokenSource: Int64] {
        modelUsages.reduce(into: [:]) { result, usage in
            result[usage.source, default: 0] += usage.tokens.totalTokens
        }
    }
}

enum TokenPriceCurrency: String, Codable {
    case usd
    case cny
}

struct TokenCostEstimate: Equatable {
    var nativeUSD = 0.0
    var nativeCNY = 0.0
    var pricedTokens: Int64 = 0
    var unpricedTokens: Int64 = 0
    var unpricedModels: Set<String> = []

    func totalUSD(usdToCNY: Double) -> Double {
        nativeUSD + nativeCNY / max(usdToCNY, 0.01)
    }

    func totalCNY(usdToCNY: Double) -> Double {
        nativeCNY + nativeUSD * max(usdToCNY, 0.01)
    }
}

struct TokenUsageSnapshot: Equatable {
    let generatedAt: Date
    let days: [DailyTokenUsage]
    let errorMessage: String?

    static let empty = TokenUsageSnapshot(generatedAt: .distantPast, days: [], errorMessage: nil)

    var todayTokens: Int64 { totalTokens(last: 1) }
    var last7DaysTokens: Int64 { totalTokens(last: 7) }
    var last30DaysTokens: Int64 { totalTokens(last: 30) }

    func totalTokens(last dayCount: Int) -> Int64 {
        days.suffix(max(0, dayCount)).reduce(0) { $0 + $1.totalTokens }
    }

    func totalTokens(for source: TokenSource, last dayCount: Int) -> Int64 {
        days.suffix(max(0, dayCount)).reduce(0) { total, day in
            total + (day.sourceTotals[source] ?? 0)
        }
    }

    func modelUsages(last dayCount: Int) -> [ModelTokenUsage] {
        var result: [String: ModelTokenUsage] = [:]
        for usage in days.suffix(max(0, dayCount)).flatMap(\.modelUsages) {
            if var current = result[usage.id] {
                current.tokens += usage.tokens
                result[usage.id] = current
            } else {
                result[usage.id] = usage
            }
        }
        return result.values.sorted {
            if $0.tokens.totalTokens == $1.tokens.totalTokens { return $0.displayName < $1.displayName }
            return $0.tokens.totalTokens > $1.tokens.totalTokens
        }
    }

    func apiCost(last dayCount: Int) -> TokenCostEstimate {
        estimateAPICost(for: modelUsages(last: dayCount))
    }

    func apiCost(for source: TokenSource, last dayCount: Int) -> TokenCostEstimate {
        estimateAPICost(for: modelUsages(last: dayCount).filter { $0.source == source })
    }
}

struct DeviceTokenUsageSummary: Equatable, Identifiable {
    let deviceId: String
    let deviceName: String
    let isCurrentDevice: Bool
    let todayTokens: Int64
    let last7DaysTokens: Int64
    let last30DaysTokens: Int64

    var id: String { deviceId }
    var displayName: String { isCurrentDevice ? "\(deviceName) · 本机" : deviceName }

    init(
        deviceId: String,
        deviceName: String,
        isCurrentDevice: Bool,
        snapshot: TokenUsageSnapshot
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.isCurrentDevice = isCurrentDevice
        todayTokens = snapshot.todayTokens
        last7DaysTokens = snapshot.last7DaysTokens
        last30DaysTokens = snapshot.last30DaysTokens
    }

    func totalTokens(last dayCount: Int) -> Int64 {
        switch dayCount {
        case 1: return todayTokens
        case 7: return last7DaysTokens
        case 30: return last30DaysTokens
        default: return last30DaysTokens
        }
    }
}

func estimateAPICost(for usages: [ModelTokenUsage]) -> TokenCostEstimate {
    usages.reduce(into: TokenCostEstimate()) { estimate, usage in
        guard usage.tokens.totalTokens > 0 else { return }
        guard let pricing = ModelPricingCatalog.pricing(provider: usage.provider, model: usage.model) else {
            estimate.unpricedTokens += usage.tokens.totalTokens
            estimate.unpricedModels.insert(usage.displayName)
            return
        }

        let cost = pricing.cost(for: usage.tokens)
        switch pricing.currency {
        case .usd: estimate.nativeUSD += cost
        case .cny: estimate.nativeCNY += cost
        }
        estimate.pricedTokens += usage.tokens.totalTokens
    }
}

private struct ModelPricing {
    let currency: TokenPriceCurrency
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double
    let output: Double

    func cost(for tokens: TokenBreakdown) -> Double {
        let raw = Double(tokens.input) * input
            + Double(tokens.cachedInput) * cachedInput
            + Double(tokens.cacheWrite) * cacheWrite
            + Double(tokens.output + tokens.reasoning) * output
        return raw / 1_000_000
    }
}

private enum ModelPricingCatalog {
    // 标准公开 API 单价，最后核对日期：2026-07-13。官方来源见 README。
    static func pricing(provider rawProvider: String, model rawModel: String) -> ModelPricing? {
        let provider = rawProvider.lowercased()
        let model = rawModel.lowercased()

        // provider 是采集来源，不代表模型厂商。同名已知模型始终使用其第一方公开价格。
        if model == "gpt-5.6-sol-pro" || model.hasPrefix("gpt-5.6-sol-pro-") {
            return nil
        }
        // 先匹配 pro，避免被同系列标准型号的前缀规则吞掉。
        if model == "gpt-5.5-pro" || model.hasPrefix("gpt-5.5-pro-") {
            return usd(input: 30, cached: 30, write: 30, output: 180)
        }
        if model == "gpt-5.2-codex" || model.hasPrefix("gpt-5.2-codex-") {
            return usd(input: 1.75, cached: 0.175, write: 1.75, output: 14)
        }
        if model == "gpt-5.2" || model.hasPrefix("gpt-5.2-20") {
            return usd(input: 1.75, cached: 0.175, write: 1.75, output: 14)
        }
        if model == "gpt-5.4" || model.hasPrefix("gpt-5.4-20") {
            return usd(input: 2.5, cached: 0.25, write: 2.5, output: 15)
        }
        if model == "gpt-5.5" || model.hasPrefix("gpt-5.5-") {
            return usd(input: 5, cached: 0.5, write: 6.25, output: 30)
        }
        if model == "gpt-5.6-sol" || model.hasPrefix("gpt-5.6-sol-") {
            return usd(input: 5, cached: 0.5, write: 6.25, output: 30)
        }
        if model == "gpt-5.6-terra" || model.hasPrefix("gpt-5.6-terra-") {
            return usd(input: 2.5, cached: 0.25, write: 3.125, output: 15)
        }
        if model == "gpt-5.6-luna" || model.hasPrefix("gpt-5.6-luna-") {
            return usd(input: 1, cached: 0.1, write: 1.25, output: 6)
        }

        if model.contains("claude-opus-4-8") {
            return usd(input: 5, cached: 0.5, write: 6.25, output: 25)
        }
        if model.contains("claude-fable-5") {
            return usd(input: 10, cached: 1, write: 12.5, output: 50)
        }
        if model.contains("claude-haiku-4-5") {
            return usd(input: 1, cached: 0.1, write: 1.25, output: 5)
        }

        if model == "glm-5.2" || model.hasPrefix("glm-5.2-") {
            return cny(input: 8, cached: 2, write: 0, output: 28)
        }
        if model == "glm-5.1" || model.hasPrefix("glm-5.1-") {
            // 聚合日志无法还原每次请求是否跨过 32K 阶梯，采用官方 <32K 档。
            return cny(input: 6, cached: 1.3, write: 0, output: 24)
        }

        if model == "deepseek-v4-pro" || model.hasPrefix("deepseek-v4-pro-") {
            return usd(input: 0.435, cached: 0.003625, write: 0.435, output: 0.87)
        }

        if model == "qwen3.7-max" || model.hasPrefix("qwen3.7-max-") {
            return cny(input: 12, cached: 12, write: 12, output: 36)
        }

        if provider == "llama-cpp" || provider == "llama.cpp" {
            return usd(input: 0, cached: 0, write: 0, output: 0)
        }

        return nil
    }

    private static func usd(input: Double, cached: Double, write: Double, output: Double) -> ModelPricing {
        ModelPricing(currency: .usd, input: input, cachedInput: cached, cacheWrite: write, output: output)
    }

    private static func cny(input: Double, cached: Double, write: Double, output: Double) -> ModelPricing {
        ModelPricing(currency: .cny, input: input, cachedInput: cached, cacheWrite: write, output: output)
    }
}

func formatTokenCount(_ value: Int64) -> String {
    let number = Double(value)
    if value >= 1_000_000_000 {
        return String(format: "%.1fB", number / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return "\(value)"
}

func formatTokenCost(_ estimate: TokenCostEstimate, currency: String, usdToCNY: Double) -> String {
    let usd = formatTokenCostUSD(estimate, usdToCNY: usdToCNY)
    let cny = formatTokenCostCNY(estimate, usdToCNY: usdToCNY)
    switch currency {
    case "usd": return usd
    case "cny": return cny
    default: return "\(usd) · \(cny)"
    }
}

func formatTokenCostUSD(_ estimate: TokenCostEstimate, usdToCNY: Double) -> String {
    formatMoney(estimate.totalUSD(usdToCNY: usdToCNY), symbol: "$")
}

func formatTokenCostCNY(_ estimate: TokenCostEstimate, usdToCNY: Double) -> String {
    formatMoney(estimate.totalCNY(usdToCNY: usdToCNY), symbol: "¥")
}

private func formatMoney(_ value: Double, symbol: String) -> String {
    if value > 0, value < 0.01 {
        return String(format: "%@%.4f", symbol, value)
    }
    return String(format: "%@%.2f", symbol, value)
}

func tokenHeatLevel(_ value: Int64) -> Int {
    switch value {
    case ..<1: return 0
    case ..<10_000_000: return 1
    case ..<100_000_000: return 2
    default: return 3
    }
}
