import Combine
import Foundation

final class TokenUsageMonitor: ObservableObject {
    @Published private(set) var snapshot: TokenUsageSnapshot = .empty
    @Published private(set) var deviceUsages: [DeviceTokenUsageSummary] = []
    @Published private(set) var isLoading = false

    private let queue = DispatchQueue(label: "com.zfstat.token-usage", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var store = TokenUsageStore.load()
    private let syncService = TokenSyncService.shared
    private var lastCollectionErrors: [String] = []
    private var started = false

    func start(interval: TimeInterval) {
        guard !started else { return }
        started = true

        publishSnapshot()
        refresh(includeHistory: !store.hasRecentData)

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + interval, repeating: interval)
        newTimer.setEventHandler { [weak self] in
            self?.collect(days: 2)
        }
        newTimer.resume()
        timer = newTimer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        started = false
    }

    func refresh() {
        refresh(includeHistory: false)
    }

    private func refresh(includeHistory: Bool) {
        DispatchQueue.main.async { [weak self] in self?.isLoading = true }
        queue.async { [weak self] in
            guard let self else { return }
            self.collect(days: includeHistory ? 30 : 2)

            // 首次启动先提供 30 天汇总，再继续补齐 GitHub 风格的近一年热力图。
            if includeHistory {
                self.collect(days: 365)
            }
        }
    }

    private func collect(days: Int) {
        let previousDaily = store.daily
        let sources = AppPreferences.shared.enabledTokenSources
        let collector = TokenUsageCollector(store: store)
        let result = collector.collect(days: days, sources: sources)
        store = result.store
        store.save()
        lastCollectionErrors = result.errors

        let changedDays = Set(previousDaily.keys).union(store.daily.keys).filter {
            previousDaily[$0] != store.daily[$0]
        }
        syncService.markDirty(days: Set(changedDays))

        let newSnapshot = combinedSnapshot(remoteDaily: syncService.cachedRemoteDaily())
        let newDeviceUsages = combinedDeviceUsages()
        DispatchQueue.main.async { [weak self] in
            self?.snapshot = newSnapshot
            self?.deviceUsages = newDeviceUsages
            self?.isLoading = false
        }

        syncService.requestSync(localStore: store) { [weak self] remoteDaily in
            guard let self else { return }
            self.queue.async {
                let syncedSnapshot = self.combinedSnapshot(remoteDaily: remoteDaily)
                let syncedDeviceUsages = self.combinedDeviceUsages()
                DispatchQueue.main.async { [weak self] in
                    self?.snapshot = syncedSnapshot
                    self?.deviceUsages = syncedDeviceUsages
                }
            }
        }
    }

    private func publishSnapshot() {
        snapshot = combinedSnapshot(remoteDaily: syncService.cachedRemoteDaily())
        deviceUsages = combinedDeviceUsages()
    }

    private func combinedSnapshot(
        remoteDaily: [String: [String: ModelTokenUsage]]
    ) -> TokenUsageSnapshot {
        var combined = store
        for (day, usages) in remoteDaily {
            for (id, usage) in usages {
                combined.daily[day, default: [:]][id] = usage
            }
        }
        return combined.snapshot(days: 365, errors: lastCollectionErrors)
    }

    private func combinedDeviceUsages() -> [DeviceTokenUsageSummary] {
        let prefs = AppPreferences.shared
        let trimmedName = prefs.tokenSyncDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDevice = DeviceTokenUsageSummary(
            deviceId: prefs.tokenSyncDeviceID,
            deviceName: trimmedName.isEmpty ? "本机" : trimmedName,
            isCurrentDevice: true,
            snapshot: store.snapshot(days: 365, errors: [])
        )
        return ([currentDevice] + syncService.cachedRemoteDeviceUsages())
            .filter { $0.last30DaysTokens > 0 }
            .sorted {
                if $0.last30DaysTokens == $1.last30DaysTokens {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return $0.last30DaysTokens > $1.last30DaysTokens
            }
    }
}

// MARK: - Collector

private struct TokenUsageCollector {
    var store: TokenUsageStore

    func collect(days: Int, sources: Set<TokenSource>) -> (store: TokenUsageStore, errors: [String]) {
        var updatedStore = store
        var errors: [String] = []
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: endDate) ?? endDate

        if sources.contains(.opencode) {
            do {
                let values = try loadOpenCode(from: startDate)
                updatedStore.replace(source: .opencode, from: startDate, through: endDate, with: values)
            } catch {
                errors.append("OpenCode：\(error.localizedDescription)")
            }
        } else {
            updatedStore.remove(source: .opencode)
        }

        if sources.contains(.zcode) {
            do {
                let values = try loadZCode(from: startDate)
                updatedStore.replace(source: .zcode, from: startDate, through: endDate, with: values)
            } catch {
                errors.append("ZCode：\(error.localizedDescription)")
            }
        } else {
            updatedStore.remove(source: .zcode)
        }

        if sources.contains(.claude) {
            do {
                let values = try loadClaude(from: startDate, through: endDate)
                updatedStore.replace(source: .claude, from: startDate, through: endDate, with: values)
            } catch {
                errors.append("Claude Code：\(error.localizedDescription)")
            }
        } else {
            updatedStore.remove(source: .claude)
        }

        if sources.contains(.codex) {
            do {
                let result = try loadCodex(from: startDate, through: endDate, fileCache: updatedStore.codexFiles)
                updatedStore.codexFiles = result.fileCache
                updatedStore.replace(source: .codex, from: startDate, through: endDate, with: result.daily)
            } catch {
                errors.append("Codex：\(error.localizedDescription)")
            }
        } else {
            updatedStore.remove(source: .codex)
        }

        return (updatedStore, errors)
    }

    private func loadOpenCode(from startDate: Date) throws -> [String: [String: ModelTokenUsage]] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }

        let startMilliseconds = Int64(startDate.timeIntervalSince1970 * 1_000)
        let query = """
        SELECT date(time_created / 1000, 'unixepoch', 'localtime') AS day,
               COALESCE(json_extract(data, '$.providerID'), 'unknown') AS provider,
               json_extract(data, '$.modelID') AS model,
               SUM(COALESCE(json_extract(data, '$.tokens.input'), 0)) AS input,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'), 0)) AS cachedInput,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cacheWrite,
               SUM(COALESCE(json_extract(data, '$.tokens.output'), 0)) AS output,
               SUM(COALESCE(json_extract(data, '$.tokens.reasoning'), 0)) AS reasoning
        FROM message
        WHERE time_created >= \(startMilliseconds)
          AND json_extract(data, '$.modelID') IS NOT NULL
        GROUP BY day, provider, model
        ORDER BY day, provider, model;
        """

        let rows: [SQLiteTokenRow] = try runSQLiteJSONQuery(databaseURL: databaseURL, query: query)
        return rows.reduce(into: [:]) { result, row in
            let usage = ModelTokenUsage(
                source: .opencode,
                provider: row.provider,
                model: row.model,
                tokens: TokenBreakdown(
                    input: Int64(row.input),
                    cachedInput: Int64(row.cachedInput),
                    cacheWrite: Int64(row.cacheWrite),
                    output: Int64(row.output),
                    reasoning: Int64(row.reasoning)
                )
            )
            result[row.day, default: [:]][usage.id] = usage
        }
    }

    private func loadZCode(from startDate: Date) throws -> [String: [String: ModelTokenUsage]] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }

        let startMilliseconds = Int64(startDate.timeIntervalSince1970 * 1_000)
        let query = """
        SELECT date(started_at / 1000, 'unixepoch', 'localtime') AS day,
               CASE provider_id
                   WHEN 'builtin:bigmodel-coding-plan' THEN 'zhipuai-coding-plan'
                   ELSE provider_id
               END AS provider,
               model_id AS model,
               SUM(input_tokens) AS input,
               SUM(cache_read_input_tokens) AS cachedInput,
               SUM(cache_creation_input_tokens) AS cacheWrite,
               SUM(output_tokens) AS output,
               SUM(reasoning_tokens) AS reasoning
        FROM model_usage
        WHERE started_at >= \(startMilliseconds)
          AND model_id IS NOT NULL
        GROUP BY day, provider, model
        ORDER BY day, provider, model;
        """

        let rows: [SQLiteTokenRow] = try runSQLiteJSONQuery(databaseURL: databaseURL, query: query)
        return rows.reduce(into: [:]) { result, row in
            let usage = ModelTokenUsage(
                source: .zcode,
                provider: row.provider,
                model: row.model,
                tokens: zcodeTokenBreakdown(
                    inputIncludingCache: Int64(row.input),
                    cacheRead: Int64(row.cachedInput),
                    cacheWrite: Int64(row.cacheWrite),
                    output: Int64(row.output),
                    reasoning: Int64(row.reasoning)
                )
            )
            result[row.day, default: [:]][usage.id] = usage
        }
    }

    private func runSQLiteJSONQuery<Row: Decodable>(databaseURL: URL, query: String) throws -> [Row] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, query]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "无法读取数据库"
            throw TokenUsageError.readFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([Row].self, from: data)
    }

    private func loadClaude(from startDate: Date, through endDate: Date) throws -> [String: [String: ModelTokenUsage]] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var requests: [String: (day: String, usage: ModelTokenUsage)] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  (values?.contentModificationDate ?? .distantPast) >= startDate else { continue }

            try JSONLReader.read(fileURL) { data in
                guard data.range(of: Data("\"assistant\"".utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      let timestamp = object["timestamp"] as? String,
                      let date = parseISO8601(timestamp),
                      date >= startDate,
                      date < Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate,
                      let requestID = (object["requestId"] as? String)
                        ?? (message["id"] as? String)
                        ?? (object["uuid"] as? String) else { return }

                let modelUsage = ModelTokenUsage(
                    source: .claude,
                    provider: "anthropic",
                    model: model,
                    tokens: TokenBreakdown(
                        input: int64(usage["input_tokens"]),
                        cachedInput: int64(usage["cache_read_input_tokens"]),
                        cacheWrite: int64(usage["cache_creation_input_tokens"]),
                        output: int64(usage["output_tokens"])
                    )
                )
                requests[requestID] = (dayKey(date), modelUsage)
            }
        }

        return requests.values.reduce(into: [:]) { result, item in
            mergeUsage(item.usage, into: &result[item.day, default: [:]])
        }
    }

    private func loadCodex(
        from startDate: Date,
        through endDate: Date,
        fileCache: [String: CodexFileCache]
    ) throws -> (daily: [String: [String: ModelTokenUsage]], fileCache: [String: CodexFileCache]) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: root.path) else { return ([:], fileCache) }

        var updatedCache = fileCache
        var daily: [String: [String: ModelTokenUsage]] = [:]
        let calendar = Calendar.current
        let folderStart = calendar.date(byAdding: .day, value: -1, to: startDate) ?? startDate
        let folderEnd = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        var folderDate = folderStart

        while folderDate <= folderEnd {
            let components = calendar.dateComponents([.year, .month, .day], from: folderDate)
            let folder = root
                .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))

            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in files where fileURL.pathExtension == "jsonl" {
                let path = fileURL.path
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = UInt64(values.fileSize ?? 0)
                let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let cached = updatedCache[path]

                if let cached, cached.byteOffset == size, cached.modifiedAt == modifiedAt {
                    merge(cached.daily, into: &daily, from: startDate, through: endDate)
                    continue
                }

                let canAppend = cached != nil && size >= (cached?.byteOffset ?? 0)
                let offset = canAppend ? (cached?.byteOffset ?? 0) : 0
                var fileDaily = canAppend ? (cached?.daily ?? [:]) : [:]
                var currentModel = canAppend ? (cached?.lastModel ?? "未知模型") : "未知模型"

                try JSONLReader.read(fileURL, from: offset) { data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                    if object["type"] as? String == "turn_context",
                       let payload = object["payload"] as? [String: Any],
                       let model = payload["model"] as? String {
                        currentModel = model
                        return
                    }

                    guard object["type"] as? String == "event_msg",
                          let payload = object["payload"] as? [String: Any],
                          payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let usage = info["last_token_usage"] as? [String: Any],
                          let timestamp = object["timestamp"] as? String,
                          let date = parseISO8601(timestamp) else { return }

                    // Codex 的 input_tokens 已含 cached_input_tokens；output_tokens 已含推理输出。
                    let cachedInput = int64(usage["cached_input_tokens"])
                    let modelUsage = ModelTokenUsage(
                        source: .codex,
                        provider: "openai",
                        model: currentModel,
                        tokens: TokenBreakdown(
                            input: max(0, int64(usage["input_tokens"]) - cachedInput),
                            cachedInput: cachedInput,
                            output: int64(usage["output_tokens"])
                        )
                    )
                    mergeUsage(modelUsage, into: &fileDaily[dayKey(date), default: [:]])
                }

                let entry = CodexFileCache(
                    byteOffset: size,
                    modifiedAt: modifiedAt,
                    lastModel: currentModel,
                    daily: fileDaily
                )
                updatedCache[path] = entry
                merge(entry.daily, into: &daily, from: startDate, through: endDate)
            }

            folderDate = calendar.date(byAdding: .day, value: 1, to: folderDate) ?? folderEnd.addingTimeInterval(1)
        }

        return (daily, updatedCache)
    }

    private func merge(
        _ source: [String: [String: ModelTokenUsage]],
        into destination: inout [String: [String: ModelTokenUsage]],
        from startDate: Date,
        through endDate: Date
    ) {
        let start = dayKey(startDate)
        let end = dayKey(endDate)
        for (key, usages) in source where key >= start && key <= end {
            for usage in usages.values {
                mergeUsage(usage, into: &destination[key, default: [:]])
            }
        }
    }
}

private struct SQLiteTokenRow: Decodable {
    let day: String
    let provider: String
    let model: String
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double
    let output: Double
    let reasoning: Double
}

private enum TokenUsageError: LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message): return message
        }
    }
}

// MARK: - JSONL helpers

private enum JSONLReader {
    static func read(_ url: URL, from offset: UInt64 = 0, handler: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        let newline = Data([0x0A])
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            while let range = buffer.range(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                if !line.isEmpty { handler(line) }
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            }
        }
        if !buffer.isEmpty { handler(buffer) }
    }
}

private func int64(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) ?? 0 }
    return 0
}

func zcodeTokenBreakdown(
    inputIncludingCache: Int64,
    cacheRead: Int64,
    cacheWrite: Int64,
    output: Int64,
    reasoning: Int64
) -> TokenBreakdown {
    let safeCacheRead = max(0, cacheRead)
    let safeCacheWrite = max(0, cacheWrite)
    return TokenBreakdown(
        input: max(0, inputIncludingCache - safeCacheRead - safeCacheWrite),
        cachedInput: safeCacheRead,
        cacheWrite: safeCacheWrite,
        output: max(0, output),
        reasoning: max(0, reasoning)
    )
}

private func mergeUsage(_ usage: ModelTokenUsage, into destination: inout [String: ModelTokenUsage]) {
    if var current = destination[usage.id] {
        current.tokens += usage.tokens
        destination[usage.id] = current
    } else {
        destination[usage.id] = usage
    }
}

private let localDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let fractionalISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let ISO8601Formatter = ISO8601DateFormatter()

private func parseISO8601(_ value: String) -> Date? {
    fractionalISO8601Formatter.date(from: value) ?? ISO8601Formatter.date(from: value)
}

private func dayKey(_ date: Date) -> String {
    localDayFormatter.string(from: date)
}
