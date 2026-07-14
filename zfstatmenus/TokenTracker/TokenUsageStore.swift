import Foundation
import SQLite3

struct TokenUsageStore: Codable {
    var daily: [String: [String: ModelTokenUsage]] = [:]
    var codexFiles: [String: CodexFileCache] = [:]

    var hasRecentData: Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
        return daily.keys.contains { $0 >= tokenStoreDayKey(cutoff) }
    }

    mutating func replace(
        source: TokenSource,
        from startDate: Date,
        through endDate: Date,
        with values: [String: [String: ModelTokenUsage]]
    ) {
        var date = Calendar.current.startOfDay(for: startDate)
        let end = Calendar.current.startOfDay(for: endDate)
        while date <= end {
            let key = tokenStoreDayKey(date)
            daily[key] = (daily[key] ?? [:]).filter { $0.value.source != source }
            for (id, usage) in values[key] ?? [:] {
                daily[key, default: [:]][id] = usage
            }
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? end.addingTimeInterval(1)
        }
    }

    mutating func remove(source: TokenSource) {
        for key in Array(daily.keys) {
            daily[key] = daily[key]?.filter { $0.value.source != source }
        }
    }

    func snapshot(days dayCount: Int, errors: [String]) -> TokenUsageSnapshot {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(max(dayCount, 1) - 1), to: end) ?? end
        var date = start
        var result: [DailyTokenUsage] = []

        while date <= end {
            let usagesByModel = (daily[tokenStoreDayKey(date)] ?? [:]).values.reduce(
                into: [String: ModelTokenUsage]()
            ) { result, usage in
                if var existing = result[usage.id] {
                    existing.tokens += usage.tokens
                    result[usage.id] = existing
                } else {
                    result[usage.id] = usage
                }
            }
            let usages = usagesByModel.values.sorted { $0.id < $1.id }
            result.append(DailyTokenUsage(date: date, modelUsages: usages))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? end.addingTimeInterval(1)
        }

        return TokenUsageSnapshot(
            generatedAt: Date(),
            days: result,
            errorMessage: errors.isEmpty ? nil : errors.joined(separator: "；")
        )
    }

    static func load(
        databaseURL: URL = defaultDatabaseURL,
        legacyJSONURL: URL? = defaultLegacyJSONURL
    ) -> TokenUsageStore {
        do {
            let storage = try TokenUsageSQLiteStorage(url: databaseURL)
            var store = try storage.loadStore()
            if !storage.hasCompletedLegacyImport {
                if let legacyJSONURL,
                   let data = try? Data(contentsOf: legacyJSONURL),
                   let legacyStore = try? JSONDecoder().decode(TokenUsageStore.self, from: data) {
                    store = legacyStore
                    try storage.save(store)
                }
                try storage.markLegacyImportCompleted()
            }
            return store
        } catch {
            AppLog.general.error("Token SQLite cache load failed: \(error.localizedDescription)")
            return TokenUsageStore()
        }
    }

    func save(databaseURL: URL = defaultDatabaseURL) {
        do {
            try TokenUsageSQLiteStorage(url: databaseURL).save(self)
        } catch {
            AppLog.general.error("Token SQLite cache save failed: \(error.localizedDescription)")
        }
    }

    static var defaultDatabaseURL: URL {
        applicationSupportFolder.appendingPathComponent("token-usage-cache.sqlite3")
    }

    static var defaultLegacyJSONURL: URL {
        applicationSupportFolder.appendingPathComponent("token-usage-cache-v2.json")
    }

    private static var applicationSupportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ZFStatMenus")
    }
}

struct CodexFileCache: Codable {
    let byteOffset: UInt64
    let modifiedAt: TimeInterval
    let lastModel: String
    let daily: [String: [String: ModelTokenUsage]]
}

private final class TokenUsageSQLiteStorage {
    private static let schemaVersion = 2
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(database)
            database = nil
            throw SQLiteCacheError(message)
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 3000")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try migrateIfNeeded()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    var hasCompletedLegacyImport: Bool {
        (try? scalarText("SELECT value FROM metadata WHERE key = 'legacy_json_imported'")) == "1"
    }

    func markLegacyImportCompleted() throws {
        try execute("INSERT OR REPLACE INTO metadata(key, value) VALUES ('legacy_json_imported', '1')")
    }

    func loadStore() throws -> TokenUsageStore {
        var store = TokenUsageStore()
        try queryUsages(
            sql: """
                SELECT day, usage_id, source, provider, model, input_tokens, cached_input_tokens,
                       cache_write_tokens, output_tokens, reasoning_tokens
                FROM daily_usage
                """
        ) { day, id, usage in
            store.daily[day, default: [:]][id] = usage
        }

        let fileStatement = try prepare(
            "SELECT path, byte_offset, modified_at, last_model FROM codex_file"
        )
        defer { sqlite3_finalize(fileStatement) }
        while sqlite3_step(fileStatement) == SQLITE_ROW {
            let path = text(fileStatement, 0)
            store.codexFiles[path] = CodexFileCache(
                byteOffset: UInt64(max(0, sqlite3_column_int64(fileStatement, 1))),
                modifiedAt: sqlite3_column_double(fileStatement, 2),
                lastModel: text(fileStatement, 3),
                daily: [:]
            )
        }
        try ensureCompleted(fileStatement)

        try queryUsages(
            sql: """
                SELECT day, usage_id, source, provider, model, input_tokens, cached_input_tokens,
                       cache_write_tokens, output_tokens, reasoning_tokens, path
                FROM codex_file_usage
                """
        ) { day, id, usage, statement in
            let path = self.text(statement, 10)
            guard let cached = store.codexFiles[path] else { return }
            var daily = cached.daily
            daily[day, default: [:]][id] = usage
            store.codexFiles[path] = CodexFileCache(
                byteOffset: cached.byteOffset,
                modifiedAt: cached.modifiedAt,
                lastModel: cached.lastModel,
                daily: daily
            )
        }
        return store
    }

    func save(_ store: TokenUsageStore) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM daily_usage")
            try execute("DELETE FROM codex_file")

            let dailyStatement = try prepare(
                """
                INSERT INTO daily_usage(
                    day, usage_id, source, provider, model, input_tokens, cached_input_tokens,
                    cache_write_tokens, output_tokens, reasoning_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(dailyStatement) }
            for (day, usages) in store.daily {
                for (id, usage) in usages {
                    try insertUsage(usage, day: day, id: id, into: dailyStatement)
                }
            }

            let fileStatement = try prepare(
                "INSERT INTO codex_file(path, byte_offset, modified_at, last_model) VALUES (?, ?, ?, ?)"
            )
            defer { sqlite3_finalize(fileStatement) }
            let fileUsageStatement = try prepare(
                """
                INSERT INTO codex_file_usage(
                    path, day, usage_id, source, provider, model, input_tokens, cached_input_tokens,
                    cache_write_tokens, output_tokens, reasoning_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(fileUsageStatement) }

            for (path, cached) in store.codexFiles {
                sqlite3_reset(fileStatement)
                sqlite3_clear_bindings(fileStatement)
                bind(path, to: 1, in: fileStatement)
                sqlite3_bind_int64(fileStatement, 2, Int64(clamping: cached.byteOffset))
                sqlite3_bind_double(fileStatement, 3, cached.modifiedAt)
                bind(cached.lastModel, to: 4, in: fileStatement)
                try stepDone(fileStatement)

                for (day, usages) in cached.daily {
                    for (id, usage) in usages {
                        sqlite3_reset(fileUsageStatement)
                        sqlite3_clear_bindings(fileUsageStatement)
                        bind(path, to: 1, in: fileUsageStatement)
                        try bindUsage(usage, day: day, id: id, startingAt: 2, in: fileUsageStatement)
                        try stepDone(fileUsageStatement)
                    }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrateIfNeeded() throws {
        let version = Int(scalarInt("PRAGMA user_version"))
        guard version <= Self.schemaVersion else {
            throw SQLiteCacheError("缓存数据库版本 \(version) 高于当前支持版本 \(Self.schemaVersion)")
        }
        if version < 1 {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("""
                    CREATE TABLE metadata(
                        key TEXT PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL
                    ) WITHOUT ROWID
                    """)
                try execute("""
                    CREATE TABLE daily_usage(
                        day TEXT NOT NULL,
                        usage_id TEXT NOT NULL,
                        source TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        model TEXT NOT NULL,
                        input_tokens INTEGER NOT NULL,
                        cached_input_tokens INTEGER NOT NULL,
                        cache_write_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL,
                        reasoning_tokens INTEGER NOT NULL,
                        PRIMARY KEY(day, usage_id)
                    ) WITHOUT ROWID
                    """)
                try execute("""
                    CREATE TABLE codex_file(
                        path TEXT PRIMARY KEY NOT NULL,
                        byte_offset INTEGER NOT NULL,
                        modified_at REAL NOT NULL,
                        last_model TEXT NOT NULL
                    ) WITHOUT ROWID
                    """)
                try execute("""
                    CREATE TABLE codex_file_usage(
                        path TEXT NOT NULL REFERENCES codex_file(path) ON DELETE CASCADE,
                        day TEXT NOT NULL,
                        usage_id TEXT NOT NULL,
                        source TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        model TEXT NOT NULL,
                        input_tokens INTEGER NOT NULL,
                        cached_input_tokens INTEGER NOT NULL,
                        cache_write_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL,
                        reasoning_tokens INTEGER NOT NULL,
                        PRIMARY KEY(path, day, usage_id)
                    ) WITHOUT ROWID
                    """)
                try execute("PRAGMA user_version = 1")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        if version < 2 {
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("""
                    CREATE TABLE sync_metadata(
                        key TEXT PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL
                    ) WITHOUT ROWID
                    """)
                try execute("""
                    CREATE TABLE sync_outbox(
                        day TEXT PRIMARY KEY NOT NULL,
                        revision INTEGER NOT NULL
                    ) WITHOUT ROWID
                    """)
                try execute("""
                    CREATE TABLE remote_daily_usage(
                        device_id TEXT NOT NULL,
                        device_name TEXT NOT NULL,
                        day TEXT NOT NULL,
                        usage_id TEXT NOT NULL,
                        source TEXT NOT NULL,
                        provider TEXT NOT NULL,
                        model TEXT NOT NULL,
                        input_tokens INTEGER NOT NULL,
                        cached_input_tokens INTEGER NOT NULL,
                        cache_write_tokens INTEGER NOT NULL,
                        output_tokens INTEGER NOT NULL,
                        reasoning_tokens INTEGER NOT NULL,
                        PRIMARY KEY(device_id, day, usage_id)
                    ) WITHOUT ROWID
                    """)
                try execute("CREATE INDEX remote_daily_usage_day_idx ON remote_daily_usage(day)")
                try execute("PRAGMA user_version = 2")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func queryUsages(
        sql: String,
        handler: (String, String, ModelTokenUsage, OpaquePointer) -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = TokenSource(rawValue: text(statement, 2)) else { continue }
            let usage = ModelTokenUsage(
                source: source,
                provider: text(statement, 3),
                model: text(statement, 4),
                tokens: TokenBreakdown(
                    input: sqlite3_column_int64(statement, 5),
                    cachedInput: sqlite3_column_int64(statement, 6),
                    cacheWrite: sqlite3_column_int64(statement, 7),
                    output: sqlite3_column_int64(statement, 8),
                    reasoning: sqlite3_column_int64(statement, 9)
                )
            )
            handler(text(statement, 0), text(statement, 1), usage, statement)
        }
        try ensureCompleted(statement)
    }

    private func queryUsages(
        sql: String,
        handler: (String, String, ModelTokenUsage) -> Void
    ) throws {
        try queryUsages(sql: sql) { day, id, usage, _ in handler(day, id, usage) }
    }

    private func insertUsage(
        _ usage: ModelTokenUsage,
        day: String,
        id: String,
        into statement: OpaquePointer
    ) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bindUsage(usage, day: day, id: id, startingAt: 1, in: statement)
        try stepDone(statement)
    }

    private func bindUsage(
        _ usage: ModelTokenUsage,
        day: String,
        id: String,
        startingAt start: Int32,
        in statement: OpaquePointer
    ) throws {
        bind(day, to: start, in: statement)
        bind(id, to: start + 1, in: statement)
        bind(usage.source.rawValue, to: start + 2, in: statement)
        bind(usage.provider, to: start + 3, in: statement)
        bind(usage.model, to: start + 4, in: statement)
        sqlite3_bind_int64(statement, start + 5, usage.tokens.input)
        sqlite3_bind_int64(statement, start + 6, usage.tokens.cachedInput)
        sqlite3_bind_int64(statement, start + 7, usage.tokens.cacheWrite)
        sqlite3_bind_int64(statement, start + 8, usage.tokens.output)
        sqlite3_bind_int64(statement, start + 9, usage.tokens.reasoning)
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func scalarInt(_ sql: String) -> Int64 {
        guard let statement = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return text(statement, 0) }
        if result == SQLITE_DONE { return nil }
        throw lastError()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw lastError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastError()
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func ensureCompleted(_ statement: OpaquePointer) throws {
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw lastError()
        }
    }

    private func lastError() -> SQLiteCacheError {
        SQLiteCacheError(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 未知错误")
    }
}

private struct SQLiteCacheError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private let tokenStoreDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func tokenStoreDayKey(_ date: Date) -> String {
    tokenStoreDayFormatter.string(from: date)
}
