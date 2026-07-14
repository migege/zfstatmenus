import Combine
import CryptoKit
import Foundation
import Security
import SQLite3

enum TokenSyncPhase: Equatable {
    case disabled
    case syncing
    case synced
    case pending
    case failed
}

struct TokenSyncStatus: Equatable {
    let phase: TokenSyncPhase
    let message: String
    let pendingDays: Int
    let lastSuccessAt: Date?

    static let disabled = TokenSyncStatus(
        phase: .disabled,
        message: "同步未启用",
        pendingDays: 0,
        lastSuccessAt: nil
    )
}

struct RemoteTokenUsageRow: Codable, Equatable {
    let deviceId: String
    let deviceName: String
    let day: String
    let source: TokenSource
    let provider: String
    let model: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64

    var usage: ModelTokenUsage {
        ModelTokenUsage(
            source: source,
            provider: provider,
            model: model,
            tokens: TokenBreakdown(
                input: inputTokens,
                cachedInput: cachedInputTokens,
                cacheWrite: cacheWriteTokens,
                output: outputTokens,
                reasoning: reasoningTokens
            )
        )
    }
}

final class TokenSyncService: ObservableObject, @unchecked Sendable {
    static let shared = TokenSyncService()

    @Published private(set) var status: TokenSyncStatus

    private let queue = DispatchQueue(label: "com.zfstat.token-sync", qos: .utility)
    private var isSyncing = false
    private var rerunAfterCurrentSync = false
    private var latestStore: TokenUsageStore?
    private var lastAttemptAt: Date?
    private var nextRetryAt: Date?
    private var failureCount = 0
    private var currentStatus: TokenSyncStatus

    private init() {
        let initialStatus = AppPreferences.shared.tokenSyncEnabled
            ? TokenSyncStatus(phase: .pending, message: "等待同步", pendingDays: 0, lastSuccessAt: nil)
            : .disabled
        status = initialStatus
        currentStatus = initialStatus
    }

    var hasStoredToken: Bool {
        TokenSyncKeychain.loadToken() != nil
    }

    func saveConfiguration(
        enabled: Bool,
        serverURL: String,
        deviceName: String,
        newToken: String?
    ) throws {
        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = trimmedServerURL.isEmpty && !enabled
            ? nil
            : try Self.normalizedServerURL(trimmedServerURL)
        let normalizedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeviceName.isEmpty, normalizedDeviceName.count <= 100 else {
            throw TokenSyncError.configuration("设备名称不能为空且不能超过 100 字符")
        }

        if let newToken, !newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try TokenSyncKeychain.saveToken(newToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if enabled && TokenSyncKeychain.loadToken() == nil {
            throw TokenSyncError.configuration("请填写访问 Token")
        }

        let prefs = AppPreferences.shared
        prefs.tokenSyncServerURL = normalizedURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        prefs.tokenSyncDeviceName = normalizedDeviceName
        prefs.tokenSyncEnabled = enabled

        queue.async { [weak self] in
            guard let self else { return }
            failureCount = 0
            nextRetryAt = nil
            if !enabled {
                publish(.disabled)
                return
            }
            publish(TokenSyncStatus(phase: .pending, message: "等待同步", pendingDays: 0, lastSuccessAt: nil))
            if let latestStore {
                startSync(localStore: latestStore, force: true, completion: nil)
            }
        }
    }

    func clearToken() throws {
        try TokenSyncKeychain.deleteToken()
        AppPreferences.shared.tokenSyncEnabled = false
        queue.async { [weak self] in self?.publish(.disabled) }
    }

    func markDirty(days: Set<String>) {
        guard AppPreferences.shared.tokenSyncEnabled, !days.isEmpty else { return }
        queue.async {
            do {
                try TokenSyncSQLiteStore().markDirty(days: days)
            } catch {
                AppLog.general.error("Token sync outbox update failed: \(error.localizedDescription)")
            }
        }
    }

    func cachedRemoteDaily() -> [String: [String: ModelTokenUsage]] {
        guard AppPreferences.shared.tokenSyncEnabled else { return [:] }
        do {
            return try TokenSyncSQLiteStore().remoteDaily()
        } catch {
            AppLog.general.error("Token remote cache load failed: \(error.localizedDescription)")
            return [:]
        }
    }

    func cachedRemoteDeviceUsages() -> [DeviceTokenUsageSummary] {
        guard AppPreferences.shared.tokenSyncEnabled else { return [] }
        do {
            return try TokenSyncSQLiteStore().remoteDeviceUsages()
        } catch {
            AppLog.general.error("Token remote device cache load failed: \(error.localizedDescription)")
            return []
        }
    }

    func requestSync(
        localStore: TokenUsageStore,
        force: Bool = false,
        completion: (([String: [String: ModelTokenUsage]]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            latestStore = localStore
            startSync(localStore: localStore, force: force, completion: completion)
        }
    }

    func verifyConnection(completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let configuration = try loadConfiguration()
                publish(TokenSyncStatus(
                    phase: .syncing,
                    message: "正在验证",
                    pendingDays: currentStatus.pendingDays,
                    lastSuccessAt: currentStatus.lastSuccessAt
                ))
                Task {
                    do {
                        let user = try await TokenSyncHTTPClient(configuration: configuration).verify()
                        self.queue.async {
                            self.publish(TokenSyncStatus(
                                phase: .pending,
                                message: "认证成功 · \(user)",
                                pendingDays: self.currentStatus.pendingDays,
                                lastSuccessAt: self.currentStatus.lastSuccessAt
                            ))
                            DispatchQueue.main.async { completion(.success(user)) }
                        }
                    } catch {
                        self.queue.async {
                            self.publishFailure(error, pendingDays: self.currentStatus.pendingDays)
                            DispatchQueue.main.async { completion(.failure(error)) }
                        }
                    }
                }
            } catch {
                publishFailure(error, pendingDays: currentStatus.pendingDays)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func startSync(
        localStore: TokenUsageStore,
        force: Bool,
        completion: (([String: [String: ModelTokenUsage]]) -> Void)?
    ) {
        guard AppPreferences.shared.tokenSyncEnabled else {
            publish(.disabled)
            return
        }
        if isSyncing {
            rerunAfterCurrentSync = true
            return
        }
        if !force, let nextRetryAt, nextRetryAt > Date() {
            return
        }

        do {
            let configuration = try loadConfiguration()
            let sqliteStore = try TokenSyncSQLiteStore()
            let identity = Self.configurationIdentity(configuration)
            try sqliteStore.prepareIdentity(identity, allDays: Set(localStore.daily.keys))
            let pending = try sqliteStore.pendingDays()

            if !force,
               pending.isEmpty,
               let lastAttemptAt,
               Date().timeIntervalSince(lastAttemptAt) < 30 {
                return
            }

            isSyncing = true
            lastAttemptAt = Date()
            publish(TokenSyncStatus(
                phase: .syncing,
                message: pending.isEmpty ? "正在拉取其他设备" : "正在同步 \(pending.count) 天",
                pendingDays: pending.count,
                lastSuccessAt: sqliteStore.lastSuccessAt()
            ))

            let requestDays = pending.map { pendingDay in
                TokenSyncRequestDay(
                    day: pendingDay.day,
                    revision: pendingDay.revision,
                    usages: Array((localStore.daily[pendingDay.day] ?? [:]).values)
                        .sorted { $0.id < $1.id }
                        .map(TokenSyncRequestUsage.init)
                )
            }
            let client = TokenSyncHTTPClient(configuration: configuration)

            Task {
                do {
                    let result = try await client.sync(days: requestDays)
                    self.queue.async {
                        self.finishSync(
                            result: result,
                            completion: completion
                        )
                    }
                } catch {
                    self.queue.async {
                        self.isSyncing = false
                        self.failureCount += 1
                        let delays: [TimeInterval] = [30, 60, 120, 300, 900]
                        self.nextRetryAt = Date().addingTimeInterval(delays[min(self.failureCount - 1, delays.count - 1)])
                        let pendingCount = (try? TokenSyncSQLiteStore().pendingDays().count) ?? pending.count
                        self.publishFailure(error, pendingDays: pendingCount)
                        self.runDeferredSyncIfNeeded(completion: completion)
                    }
                }
            }
        } catch {
            publishFailure(error, pendingDays: currentStatus.pendingDays)
        }
    }

    private func finishSync(
        result: TokenSyncHTTPResult,
        completion: (([String: [String: ModelTokenUsage]]) -> Void)?
    ) {
        do {
            let sqliteStore = try TokenSyncSQLiteStore()
            try sqliteStore.clearAccepted(result.accepted)
            try sqliteStore.replaceRemote(rows: result.remoteRows)
            try sqliteStore.setLastSuccessAt(Date())
            let remote = try sqliteStore.remoteDaily()
            let pendingCount = try sqliteStore.pendingDays().count

            isSyncing = false
            failureCount = 0
            nextRetryAt = nil
            publish(TokenSyncStatus(
                phase: pendingCount == 0 ? .synced : .pending,
                message: pendingCount == 0 ? "已同步" : "待同步 \(pendingCount) 天",
                pendingDays: pendingCount,
                lastSuccessAt: Date()
            ))
            if let completion {
                DispatchQueue.main.async { completion(remote) }
            }
            runDeferredSyncIfNeeded(completion: completion)
        } catch {
            isSyncing = false
            publishFailure(error, pendingDays: currentStatus.pendingDays)
        }
    }

    private func runDeferredSyncIfNeeded(
        completion: (([String: [String: ModelTokenUsage]]) -> Void)?
    ) {
        guard rerunAfterCurrentSync, let latestStore else { return }
        rerunAfterCurrentSync = false
        startSync(localStore: latestStore, force: true, completion: completion)
    }

    private func loadConfiguration() throws -> TokenSyncConfiguration {
        let prefs = AppPreferences.shared
        let serverURL = try Self.normalizedServerURL(prefs.tokenSyncServerURL)
        guard let token = TokenSyncKeychain.loadToken() else {
            throw TokenSyncError.configuration("访问 Token 未配置")
        }
        return TokenSyncConfiguration(
            serverURL: serverURL,
            token: token,
            deviceId: prefs.tokenSyncDeviceID,
            deviceName: prefs.tokenSyncDeviceName
        )
    }

    private func publishFailure(_ error: Error, pendingDays: Int) {
        let phase: TokenSyncPhase = (error as? TokenSyncError)?.isAuthenticationError == true ? .failed : .pending
        let lastSuccessAt = (try? TokenSyncSQLiteStore().lastSuccessAt()) ?? currentStatus.lastSuccessAt
        publish(TokenSyncStatus(
            phase: phase,
            message: error.localizedDescription,
            pendingDays: pendingDays,
            lastSuccessAt: lastSuccessAt
        ))
    }

    private func publish(_ value: TokenSyncStatus) {
        currentStatus = value
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }

    private static func normalizedServerURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw TokenSyncError.configuration("服务器地址无效")
        }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw TokenSyncError.configuration("服务器地址必须使用 HTTPS（本机调试除外）")
        }
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = trimmedPath.isEmpty ? "" : "/\(trimmedPath)"
        guard let url = components.url else { throw TokenSyncError.configuration("服务器地址无效") }
        return url
    }

    private static func configurationIdentity(_ configuration: TokenSyncConfiguration) -> String {
        let tokenHash = SHA256.hash(data: Data(configuration.token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(configuration.serverURL.absoluteString)|\(configuration.deviceId)|\(tokenHash)"
    }
}

private struct TokenSyncConfiguration {
    let serverURL: URL
    let token: String
    let deviceId: String
    let deviceName: String
}

private struct TokenSyncPendingDay {
    let day: String
    let revision: Int64
}

private struct TokenSyncRequest: Encodable {
    let schemaVersion = 1
    let device: Device
    let days: [TokenSyncRequestDay]

    struct Device: Encodable {
        let id: String
        let name: String
        let appVersion: String
    }
}

private struct TokenSyncRequestDay: Encodable {
    let day: String
    let revision: Int64
    let usages: [TokenSyncRequestUsage]
}

private struct TokenSyncRequestUsage: Encodable {
    let source: String
    let provider: String
    let model: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64

    init(_ usage: ModelTokenUsage) {
        source = usage.source.rawValue
        provider = usage.provider
        model = usage.model
        inputTokens = usage.tokens.input
        cachedInputTokens = usage.tokens.cachedInput
        cacheWriteTokens = usage.tokens.cacheWrite
        outputTokens = usage.tokens.output
        reasoningTokens = usage.tokens.reasoning
    }
}

private struct TokenSyncResponse: Decodable {
    let accepted: [Accepted]

    struct Accepted: Decodable {
        let day: String
        let revision: Int64
    }
}

private struct TokenSyncSnapshotResponse: Decodable {
    let rows: [RemoteTokenUsageRow]
}

private struct TokenSyncMeResponse: Decodable {
    let user: User

    struct User: Decodable {
        let displayName: String
    }
}

private struct TokenSyncAPIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let code: String
        let message: String
    }
}

private struct TokenSyncHTTPResult {
    let accepted: [TokenSyncResponse.Accepted]
    let remoteRows: [RemoteTokenUsageRow]
}

private struct TokenSyncHTTPClient {
    let configuration: TokenSyncConfiguration

    func verify() async throws -> String {
        let request = try authorizedRequest(path: "v1/me", method: "GET")
        let response: TokenSyncMeResponse = try await send(request)
        return response.user.displayName
    }

    func sync(days: [TokenSyncRequestDay]) async throws -> TokenSyncHTTPResult {
        var accepted: [TokenSyncResponse.Accepted] = []
        for start in stride(from: 0, to: days.count, by: 31) {
            let end = min(start + 31, days.count)
            let payload = TokenSyncRequest(
                device: .init(
                    id: configuration.deviceId,
                    name: configuration.deviceName,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                ),
                days: Array(days[start..<end])
            )
            var request = try authorizedRequest(path: "v1/sync", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            let response: TokenSyncResponse = try await send(request)
            accepted.append(contentsOf: response.accepted)
        }

        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -364, to: endDate) ?? endDate
        var components = URLComponents(
            url: configuration.serverURL.appendingPathComponent("v1/snapshot"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "from", value: tokenSyncDayKey(startDate)),
            URLQueryItem(name: "to", value: tokenSyncDayKey(endDate)),
            URLQueryItem(name: "excludeDeviceId", value: configuration.deviceId),
        ]
        guard let snapshotURL = components?.url else { throw TokenSyncError.configuration("无法构造同步地址") }
        var snapshotRequest = URLRequest(url: snapshotURL)
        snapshotRequest.httpMethod = "GET"
        applyAuthorization(to: &snapshotRequest)
        let snapshot: TokenSyncSnapshotResponse = try await send(snapshotRequest)

        return TokenSyncHTTPResult(accepted: accepted, remoteRows: snapshot.rows)
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        let url = configuration.serverURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyAuthorization(to: &request)
        return request
    }

    private func applyAuthorization(to request: inout URLRequest) {
        request.timeoutInterval = 20
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("ZFStatMenus/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenSyncError.network("服务器响应无效")
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            let apiError = try? JSONDecoder().decode(TokenSyncAPIErrorResponse.self, from: data)
            let message = apiError?.error.message ?? "服务器返回 HTTP \(httpResponse.statusCode)"
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw TokenSyncError.authentication(message)
            }
            throw TokenSyncError.server(message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TokenSyncError.server("无法解析服务器响应")
        }
    }
}

private enum TokenSyncKeychain {
    private static let service = "com.zfstat.ZFStatMenus.token-sync"
    private static let account = "access-token"

    static func loadToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    static func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainError(_ status: OSStatus) -> TokenSyncError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return .configuration("Keychain 操作失败：\(message)")
    }
}

private final class TokenSyncSQLiteStore {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var database: OpaquePointer?

    init(url: URL = TokenUsageStore.defaultDatabaseURL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(database)
            database = nil
            throw TokenSyncError.database(message)
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 3000")
    }

    deinit {
        sqlite3_close(database)
    }

    func prepareIdentity(_ identity: String, allDays: Set<String>) throws {
        guard try metadata("configuration_identity") != identity else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM sync_outbox")
            try execute("DELETE FROM remote_daily_usage")
            var revision = max(Int64(Date().timeIntervalSince1970 * 1_000), try nextRevision())
            let statement = try prepare("INSERT INTO sync_outbox(day, revision) VALUES (?, ?)")
            defer { sqlite3_finalize(statement) }
            for day in allDays.sorted() {
                revision += 1
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(day, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, revision)
                try stepDone(statement)
            }
            try setMetadata("next_revision", String(revision))
            try setMetadata("configuration_identity", identity)
            try execute("DELETE FROM sync_metadata WHERE key = 'last_success_at'")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func markDirty(days: Set<String>) throws {
        guard !days.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            var revision = max(Int64(Date().timeIntervalSince1970 * 1_000), try nextRevision())
            let statement = try prepare(
                "INSERT INTO sync_outbox(day, revision) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET revision = excluded.revision"
            )
            defer { sqlite3_finalize(statement) }
            for day in days.sorted() {
                revision += 1
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(day, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, revision)
                try stepDone(statement)
            }
            try setMetadata("next_revision", String(revision))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func pendingDays() throws -> [TokenSyncPendingDay] {
        let statement = try prepare("SELECT day, revision FROM sync_outbox ORDER BY day")
        defer { sqlite3_finalize(statement) }
        var result: [TokenSyncPendingDay] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(TokenSyncPendingDay(day: text(statement, 0), revision: sqlite3_column_int64(statement, 1)))
        }
        try ensureCompleted()
        return result
    }

    func clearAccepted(_ accepted: [TokenSyncResponse.Accepted]) throws {
        guard !accepted.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare("DELETE FROM sync_outbox WHERE day = ? AND revision <= ?")
            defer { sqlite3_finalize(statement) }
            for item in accepted {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(item.day, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, item.revision)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func replaceRemote(rows: [RemoteTokenUsageRow]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM remote_daily_usage")
            let statement = try prepare(
                """
                INSERT INTO remote_daily_usage(
                    device_id, device_name, day, usage_id, source, provider, model,
                    input_tokens, cached_input_tokens, cache_write_tokens,
                    output_tokens, reasoning_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(statement) }
            for row in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let usage = row.usage
                bind(row.deviceId, to: 1, in: statement)
                bind(row.deviceName, to: 2, in: statement)
                bind(row.day, to: 3, in: statement)
                bind(usage.id, to: 4, in: statement)
                bind(row.source.rawValue, to: 5, in: statement)
                bind(row.provider, to: 6, in: statement)
                bind(row.model, to: 7, in: statement)
                sqlite3_bind_int64(statement, 8, row.inputTokens)
                sqlite3_bind_int64(statement, 9, row.cachedInputTokens)
                sqlite3_bind_int64(statement, 10, row.cacheWriteTokens)
                sqlite3_bind_int64(statement, 11, row.outputTokens)
                sqlite3_bind_int64(statement, 12, row.reasoningTokens)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func remoteDaily() throws -> [String: [String: ModelTokenUsage]] {
        let statement = try prepare(
            """
            SELECT device_id, day, source, provider, model, input_tokens, cached_input_tokens,
                   cache_write_tokens, output_tokens, reasoning_tokens
            FROM remote_daily_usage
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [String: [String: ModelTokenUsage]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = TokenSource(rawValue: text(statement, 2)) else { continue }
            let deviceId = text(statement, 0)
            let day = text(statement, 1)
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
            result[day, default: [:]]["remote|\(deviceId)|\(usage.id)"] = usage
        }
        try ensureCompleted()
        return result
    }

    func remoteDeviceUsages() throws -> [DeviceTokenUsageSummary] {
        let statement = try prepare(
            """
            SELECT device_id, device_name, day, source, provider, model,
                   input_tokens, cached_input_tokens, cache_write_tokens,
                   output_tokens, reasoning_tokens
            FROM remote_daily_usage
            """
        )
        defer { sqlite3_finalize(statement) }
        var deviceNames: [String: String] = [:]
        var deviceStores: [String: TokenUsageStore] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = TokenSource(rawValue: text(statement, 3)) else { continue }
            let deviceId = text(statement, 0)
            let deviceName = text(statement, 1)
            let day = text(statement, 2)
            let usage = ModelTokenUsage(
                source: source,
                provider: text(statement, 4),
                model: text(statement, 5),
                tokens: TokenBreakdown(
                    input: sqlite3_column_int64(statement, 6),
                    cachedInput: sqlite3_column_int64(statement, 7),
                    cacheWrite: sqlite3_column_int64(statement, 8),
                    output: sqlite3_column_int64(statement, 9),
                    reasoning: sqlite3_column_int64(statement, 10)
                )
            )
            deviceNames[deviceId] = deviceName
            var deviceStore = deviceStores[deviceId] ?? TokenUsageStore()
            deviceStore.daily[day, default: [:]][usage.id] = usage
            deviceStores[deviceId] = deviceStore
        }
        try ensureCompleted()

        return deviceStores.map { deviceId, store in
            DeviceTokenUsageSummary(
                deviceId: deviceId,
                deviceName: deviceNames[deviceId] ?? "未知设备",
                isCurrentDevice: false,
                snapshot: store.snapshot(days: 365, errors: [])
            )
        }
    }

    func setLastSuccessAt(_ date: Date) throws {
        try setMetadata("last_success_at", String(date.timeIntervalSince1970))
    }

    func lastSuccessAt() -> Date? {
        let raw: String?
        do {
            raw = try metadata("last_success_at")
        } catch {
            return nil
        }
        guard let raw, let value = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func nextRevision() throws -> Int64 {
        Int64(try metadata("next_revision") ?? "0") ?? 0
    }

    private func metadata(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM sync_metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return text(statement, 0) }
        if result == SQLITE_DONE { return nil }
        throw lastError()
    }

    private func setMetadata(_ key: String, _ value: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO sync_metadata(key, value) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(value, to: 2, in: statement)
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw lastError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func ensureCompleted() throws {
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw lastError()
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func lastError() -> TokenSyncError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 未知错误")
    }
}

private enum TokenSyncError: LocalizedError {
    case configuration(String)
    case authentication(String)
    case network(String)
    case server(String)
    case database(String)

    var isAuthenticationError: Bool {
        if case .authentication = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .authentication(let message): return "认证失败：\(message)"
        case .network(let message): return "网络错误：\(message)"
        case .server(let message): return "服务异常：\(message)"
        case .database(let message): return "本地同步缓存错误：\(message)"
        }
    }
}

private let tokenSyncDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func tokenSyncDayKey(_ date: Date) -> String {
    tokenSyncDayFormatter.string(from: date)
}
