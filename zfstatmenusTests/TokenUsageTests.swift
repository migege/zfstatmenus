import XCTest
import SQLite3
@testable import ZFStatMenus

final class TokenUsageTests: XCTestCase {
    func testSnapshotMergesSameModelStoredForDifferentDevices() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let local = ModelTokenUsage(
            source: .codex,
            provider: "openai",
            model: "gpt-5.6-sol",
            tokens: TokenBreakdown(input: 100, cachedInput: 20)
        )
        let remote = ModelTokenUsage(
            source: .codex,
            provider: "openai",
            model: "gpt-5.6-sol",
            tokens: TokenBreakdown(input: 300, output: 40)
        )
        let store = TokenUsageStore(
            daily: [
                today: [
                    "local|\(local.id)": local,
                    "remote|device-b|\(remote.id)": remote,
                ]
            ]
        )

        let usages = store.snapshot(days: 1, errors: []).days[0].modelUsages

        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages[0].model, "gpt-5.6-sol")
        XCTAssertEqual(usages[0].tokens, TokenBreakdown(input: 400, cachedInput: 20, output: 40))
    }

    func testDeviceTokenUsageSummaryReportsPeriodTotals() {
        let days = [
            DailyTokenUsage(date: Date(timeIntervalSince1970: 1_000), sourceTotals: [.codex: 100]),
            DailyTokenUsage(date: Date(timeIntervalSince1970: 2_000), sourceTotals: [.opencode: 250]),
        ]
        let summary = DeviceTokenUsageSummary(
            deviceId: "device-1",
            deviceName: "工作 Mac",
            isCurrentDevice: true,
            snapshot: TokenUsageSnapshot(generatedAt: Date(), days: days, errorMessage: nil)
        )

        XCTAssertEqual(summary.displayName, "工作 Mac · 本机")
        XCTAssertEqual(summary.totalTokens(last: 1), 250)
        XCTAssertEqual(summary.totalTokens(last: 7), 350)
        XCTAssertEqual(summary.totalTokens(last: 30), 350)
    }

    func testSettingsWindowControllerPresentsReusableWindow() async {
        await MainActor.run {
            SettingsWindowController.shared.show()

            let settingsWindows = NSApp.windows.filter {
                $0.identifier?.rawValue == "ZFStatMenus.Settings"
            }
            XCTAssertEqual(settingsWindows.count, 1)
            XCTAssertTrue(settingsWindows[0].isVisible)

            SettingsWindowController.shared.show()
            XCTAssertEqual(
                NSApp.windows.filter { $0.identifier?.rawValue == "ZFStatMenus.Settings" }.count,
                1,
                "重复点击设置按钮不应创建多个窗口"
            )
            settingsWindows[0].orderOut(nil)
        }
    }

    func testPeriodTotalsAndSourceTotals() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date())
        let days = (0..<30).map { offset in
            DailyTokenUsage(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                sourceTotals: [.opencode: 100, .zcode: 30, .codex: 20, .claude: 5]
            )
        }
        let snapshot = TokenUsageSnapshot(generatedAt: Date(), days: days, errorMessage: nil)

        XCTAssertEqual(snapshot.todayTokens, 155)
        XCTAssertEqual(snapshot.last7DaysTokens, 1_085)
        XCTAssertEqual(snapshot.last30DaysTokens, 4_650)
        XCTAssertEqual(snapshot.totalTokens(for: .codex, last: 30), 600)
        XCTAssertEqual(snapshot.totalTokens(for: .zcode, last: 30), 900)
    }

    func testTokenCountFormatting() {
        XCTAssertEqual(formatTokenCount(999), "999")
        XCTAssertEqual(formatTokenCount(1_500), "1.5K")
        XCTAssertEqual(formatTokenCount(2_500_000), "2.5M")
        XCTAssertEqual(formatTokenCount(1_200_000_000), "1.2B")
    }

    func testZCodeInputTokensAreSplitWithoutDoubleCountingCache() {
        let tokens = zcodeTokenBreakdown(
            inputIncludingCache: 184_778,
            cacheRead: 183_040,
            cacheWrite: 0,
            output: 486,
            reasoning: 0
        )

        XCTAssertEqual(tokens.input, 1_738)
        XCTAssertEqual(tokens.cachedInput, 183_040)
        XCTAssertEqual(tokens.output, 486)
        XCTAssertEqual(tokens.totalTokens, 185_264)
    }

    func testOpenAICostSeparatesCachedAndOutputTokens() {
        let usage = ModelTokenUsage(
            source: .opencode,
            provider: "openai",
            model: "gpt-5.5",
            tokens: TokenBreakdown(
                input: 1_000_000,
                cachedInput: 1_000_000,
                cacheWrite: 1_000_000,
                output: 1_000_000,
                reasoning: 1_000_000
            )
        )

        let estimate = estimateAPICost(for: [usage])

        XCTAssertEqual(estimate.nativeUSD, 71.75, accuracy: 0.0001)
        XCTAssertEqual(estimate.nativeCNY, 0)
        XCTAssertEqual(estimate.pricedTokens, 5_000_000)
        XCTAssertEqual(estimate.unpricedTokens, 0)
    }

    func testMixedCurrencyConversionAndUnknownModel() {
        let glm = ModelTokenUsage(
            source: .opencode,
            provider: "zhipuai-coding-plan",
            model: "glm-5.2",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000)
        )
        let unknown = ModelTokenUsage(
            source: .codex,
            provider: "openai",
            model: "codex-auto-review",
            tokens: TokenBreakdown(input: 500_000)
        )

        let estimate = estimateAPICost(for: [glm, unknown])

        XCTAssertEqual(estimate.nativeCNY, 36, accuracy: 0.0001)
        XCTAssertEqual(estimate.totalUSD(usdToCNY: 7.2), 5, accuracy: 0.0001)
        XCTAssertEqual(estimate.unpricedTokens, 500_000)
        XCTAssertEqual(estimate.unpricedModels, ["codex-auto-review"])
        XCTAssertEqual(formatTokenCost(estimate, currency: "cny", usdToCNY: 7.2), "¥36.00")
    }

    func testKnownModelUsesFirstPartyPricingAcrossProviders() {
        let providers = ["zhipuai-coding-plan", "opencode-go", "alibaba-cn"]
        let estimates = providers.map { provider in
            estimateAPICost(for: [
                ModelTokenUsage(
                    source: .opencode,
                    provider: provider,
                    model: "GLM-5.2",
                    tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000)
                )
            ])
        }

        for estimate in estimates {
            XCTAssertEqual(estimate.nativeCNY, 36, accuracy: 0.0001)
            XCTAssertEqual(estimate.pricedTokens, 2_000_000)
            XCTAssertEqual(estimate.unpricedTokens, 0)
        }
    }

    func testKnownModelUsesFirstPartyPricingWithUnrelatedProvider() {
        let usage = ModelTokenUsage(
            source: .opencode,
            provider: "third-party-gateway",
            model: "claude-opus-4-8",
            tokens: TokenBreakdown(input: 1_000_000)
        )

        let estimate = estimateAPICost(for: [usage])

        XCTAssertEqual(estimate.nativeUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(estimate.pricedTokens, 1_000_000)
    }

    func testInternalProductModelDoesNotInheritPublicModelPrice() {
        let usage = ModelTokenUsage(
            source: .opencode,
            provider: "openai",
            model: "gpt-5.6-sol-pro",
            tokens: TokenBreakdown(input: 1_000_000)
        )

        let estimate = estimateAPICost(for: [usage])

        XCTAssertEqual(estimate.pricedTokens, 0)
        XCTAssertEqual(estimate.unpricedTokens, 1_000_000)
    }

    func testDisplaySortsModelsByPricedCostThenTokens() {
        let usages = [
            ModelTokenUsage(
                source: .codex,
                provider: "openai",
                model: "codex-auto-review",
                tokens: TokenBreakdown(input: 10_000)
            ),
            ModelTokenUsage(
                source: .codex,
                provider: "openai",
                model: "gpt-5.5",
                tokens: TokenBreakdown(input: 1_000_000)
            ),
            ModelTokenUsage(
                source: .opencode,
                provider: "zhipuai-coding-plan",
                model: "glm-5.2",
                tokens: TokenBreakdown(input: 2_000_000)
            )
        ]

        XCTAssertEqual(
            sortedModelUsagesForDisplay(usages, usdToCNYRate: 7.2).map(\.model),
            ["gpt-5.5", "glm-5.2", "codex-auto-review"]
        )
    }

    func testDisplayHidesModelsBelowOneThousandTokens() {
        let usages = [
            ModelTokenUsage(
                source: .opencode,
                provider: "unknown",
                model: "below-threshold",
                tokens: TokenBreakdown(input: 999)
            ),
            ModelTokenUsage(
                source: .opencode,
                provider: "unknown",
                model: "at-threshold",
                tokens: TokenBreakdown(input: 1_000)
            )
        ]

        XCTAssertEqual(
            sortedModelUsagesForDisplay(usages, usdToCNYRate: 7.2).map(\.model),
            ["at-threshold"]
        )
    }

    func testDisplaySortsSourcesByPricedCostThenTokens() {
        let day = DailyTokenUsage(
            date: Date(),
            modelUsages: [
                ModelTokenUsage(
                    source: .opencode,
                    provider: "openai",
                    model: "codex-auto-review",
                    tokens: TokenBreakdown(input: 10_000_000)
                ),
                ModelTokenUsage(
                    source: .codex,
                    provider: "openai",
                    model: "gpt-5.2-codex",
                    tokens: TokenBreakdown(input: 2_000_000)
                ),
                ModelTokenUsage(
                    source: .claude,
                    provider: "anthropic",
                    model: "claude-opus-4-8",
                    tokens: TokenBreakdown(input: 1_000_000)
                ),
                ModelTokenUsage(
                    source: .zcode,
                    provider: "unknown",
                    model: "below-threshold",
                    tokens: TokenBreakdown(input: 999)
                )
            ]
        )
        let snapshot = TokenUsageSnapshot(generatedAt: Date(), days: [day], errorMessage: nil)

        XCTAssertEqual(
            sortedTokenSourcesForDisplay(snapshot, last: 1, usdToCNYRate: 7.2),
            [.claude, .codex, .opencode]
        )
    }

    func testSourceCostOnlyIncludesSelectedTool() {
        let day = DailyTokenUsage(
            date: Date(),
            modelUsages: [
                ModelTokenUsage(
                    source: .codex,
                    provider: "openai",
                    model: "gpt-5.2-codex",
                    tokens: TokenBreakdown(input: 1_000_000)
                ),
                ModelTokenUsage(
                    source: .claude,
                    provider: "anthropic",
                    model: "claude-opus-4-8",
                    tokens: TokenBreakdown(input: 1_000_000)
                )
            ]
        )
        let snapshot = TokenUsageSnapshot(generatedAt: Date(), days: [day], errorMessage: nil)

        XCTAssertEqual(snapshot.apiCost(for: .codex, last: 1).nativeUSD, 1.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.apiCost(for: .claude, last: 1).nativeUSD, 5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.apiCost(for: .opencode, last: 1).nativeUSD, 0, accuracy: 0.0001)
    }

    func testSQLiteCacheRoundTripPreservesUsageAndCodexCursor() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let databaseURL = folder.appendingPathComponent("cache.sqlite3")
        let usage = ModelTokenUsage(
            source: .codex,
            provider: "openai",
            model: "gpt-5.2-codex",
            tokens: TokenBreakdown(input: 10, cachedInput: 20, output: 30)
        )
        let store = TokenUsageStore(
            daily: ["2026-07-14": [usage.id: usage]],
            codexFiles: [
                "/tmp/session.jsonl": CodexFileCache(
                    byteOffset: 123,
                    modifiedAt: 456,
                    lastModel: usage.model,
                    daily: ["2026-07-14": [usage.id: usage]]
                )
            ]
        )

        store.save(databaseURL: databaseURL)
        let loaded = TokenUsageStore.load(databaseURL: databaseURL, legacyJSONURL: nil)

        XCTAssertEqual(loaded.daily, store.daily)
        XCTAssertEqual(loaded.codexFiles["/tmp/session.jsonl"]?.byteOffset, 123)
        XCTAssertEqual(loaded.codexFiles["/tmp/session.jsonl"]?.lastModel, usage.model)
        XCTAssertEqual(loaded.codexFiles["/tmp/session.jsonl"]?.daily, store.codexFiles["/tmp/session.jsonl"]?.daily)
    }

    func testSQLiteCacheImportsLegacyJSONOnce() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let databaseURL = folder.appendingPathComponent("cache.sqlite3")
        let legacyURL = folder.appendingPathComponent("cache-v2.json")
        let usage = ModelTokenUsage(
            source: .claude,
            provider: "anthropic",
            model: "claude-opus-4-8",
            tokens: TokenBreakdown(input: 99)
        )
        let legacyStore = TokenUsageStore(daily: ["2026-07-14": [usage.id: usage]])
        try JSONEncoder().encode(legacyStore).write(to: legacyURL)

        let imported = TokenUsageStore.load(databaseURL: databaseURL, legacyJSONURL: legacyURL)
        XCTAssertEqual(imported.daily, legacyStore.daily)

        try JSONEncoder().encode(TokenUsageStore()).write(to: legacyURL)
        let loadedAgain = TokenUsageStore.load(databaseURL: databaseURL, legacyJSONURL: legacyURL)
        XCTAssertEqual(loadedAgain.daily, legacyStore.daily)
    }

    func testSQLiteCacheCreatesSyncSchemaVersionTwo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let databaseURL = folder.appendingPathComponent("cache.sqlite3")

        TokenUsageStore().save(databaseURL: databaseURL)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqliteScalarInt(database, sql: "PRAGMA user_version"), 2)
        XCTAssertEqual(
            sqliteScalarInt(
                database,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('sync_metadata', 'sync_outbox', 'remote_daily_usage')"
            ),
            3
        )
    }

    func testHeatmapHoverSelectionLifecycle() {
        let first = DailyTokenUsage(
            date: Date(timeIntervalSince1970: 1_000),
            sourceTotals: [.codex: 100]
        )
        let second = DailyTokenUsage(
            date: Date(timeIntervalSince1970: 2_000),
            sourceTotals: [.opencode: 200, .claude: 300]
        )
        var state = TokenHeatmapHoverState()

        state.update(day: first, isHovered: true)
        XCTAssertEqual(state.day, first)

        state.update(day: second, isHovered: true)
        state.update(day: first, isHovered: false)
        XCTAssertEqual(state.day, second, "离开旧格子时不应清除当前格子的明细")

        state.update(day: second, isHovered: false)
        XCTAssertNil(state.day)
    }

    func testHeatmapUsesFixedTokenThresholds() {
        XCTAssertEqual(tokenHeatLevel(0), 0)
        XCTAssertEqual(tokenHeatLevel(4_700_000), 1)
        XCTAssertEqual(tokenHeatLevel(9_999_999), 1)
        XCTAssertEqual(tokenHeatLevel(10_000_000), 2)
        XCTAssertEqual(tokenHeatLevel(80_000_000), 2)
        XCTAssertEqual(tokenHeatLevel(99_999_999), 2)
        XCTAssertEqual(tokenHeatLevel(100_000_000), 3)
    }
}

private func sqliteScalarInt(_ database: OpaquePointer?, sql: String) -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { return -1 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int64(statement, 0)
}
