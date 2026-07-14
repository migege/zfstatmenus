import Foundation
import AppKit

enum PrefKey: String {
    case monitorInterval = "monitorInterval"
    case tokenRefreshInterval = "tokenRefreshInterval"
    case enabledStatusItems = "enabledStatusItems"
    case enabledTokenTrackers = "enabledTokenTrackers"
    case statusItemOrder = "statusItemOrder"
    case launchAtLogin = "launchAtLogin"
    case showSparkline = "showSparkline"
    case showValueText = "showValueText"
    case tokenDisplayCurrency = "tokenDisplayCurrency"
    case tokenUSDToCNYRate = "tokenUSDToCNYRate"
    case tokenStatusItemIntroduced = "tokenStatusItemIntroduced"
    case tokenZCodeSourceIntroduced = "tokenZCodeSourceIntroduced"
    case tokenSyncEnabled = "tokenSyncEnabled"
    case tokenSyncServerURL = "tokenSyncServerURL"
    case tokenSyncDeviceID = "tokenSyncDeviceID"
    case tokenSyncDeviceName = "tokenSyncDeviceName"
}

final class AppPreferences {
    static let shared = AppPreferences()
    private let defaults = UserDefaults.standard

    private init() {
        registerDefaults()
        migrateDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.monitorInterval.rawValue: 1.0,
            PrefKey.tokenRefreshInterval.rawValue: 60.0,
            PrefKey.enabledStatusItems.rawValue: ["cpu", "memory", "network"],
            PrefKey.enabledTokenTrackers.rawValue: ["opencode", "zcode", "codex", "claude"],
            PrefKey.statusItemOrder.rawValue: ["cpu", "memory", "network", "token"],
            PrefKey.launchAtLogin.rawValue: false,
            PrefKey.showSparkline.rawValue: true,
            PrefKey.showValueText.rawValue: true,
            PrefKey.tokenDisplayCurrency.rawValue: "both",
            PrefKey.tokenUSDToCNYRate.rawValue: 7.2,
            PrefKey.tokenSyncEnabled.rawValue: false,
            PrefKey.tokenSyncServerURL.rawValue: "",
            PrefKey.tokenSyncDeviceID.rawValue: "",
            PrefKey.tokenSyncDeviceName.rawValue: Host.current().localizedName ?? "Mac",
        ])
    }

    private func migrateDefaults() {
        // Token 栏目首次正式可用时自动展示一次，之后尊重用户在设置中的开关。
        if !defaults.bool(forKey: PrefKey.tokenStatusItemIntroduced.rawValue) {
            var items = enabledStatusItems
            items.insert(.token)
            enabledStatusItems = items
            defaults.set(true, forKey: PrefKey.tokenStatusItemIntroduced.rawValue)
        }

        // 新增 ZCode 采集源时默认启用一次，之后继续尊重用户在设置中的选择。
        if !defaults.bool(forKey: PrefKey.tokenZCodeSourceIntroduced.rawValue) {
            var sources = enabledTokenSources
            sources.insert(.zcode)
            enabledTokenSources = sources
            defaults.set(true, forKey: PrefKey.tokenZCodeSourceIntroduced.rawValue)
        }
    }

    var monitorInterval: Double {
        get { defaults.double(forKey: PrefKey.monitorInterval.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.monitorInterval.rawValue) }
    }

    var tokenRefreshInterval: Double {
        get { defaults.double(forKey: PrefKey.tokenRefreshInterval.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.tokenRefreshInterval.rawValue) }
    }

    var enabledStatusItems: Set<StatusItemType> {
        get {
            let raw = defaults.stringArray(forKey: PrefKey.enabledStatusItems.rawValue) ?? []
            return Set(raw.compactMap { StatusItemType(rawValue: $0) })
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: PrefKey.enabledStatusItems.rawValue) }
    }

    var statusItemOrder: [StatusItemType] {
        get {
            let raw = defaults.stringArray(forKey: PrefKey.statusItemOrder.rawValue) ?? []
            return raw.compactMap { StatusItemType(rawValue: $0) }
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: PrefKey.statusItemOrder.rawValue) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: PrefKey.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.launchAtLogin.rawValue) }
    }

    var showSparkline: Bool {
        get { defaults.bool(forKey: PrefKey.showSparkline.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.showSparkline.rawValue) }
    }

    var showValueText: Bool {
        get { defaults.bool(forKey: PrefKey.showValueText.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.showValueText.rawValue) }
    }

    var tokenDisplayCurrency: String {
        get { defaults.string(forKey: PrefKey.tokenDisplayCurrency.rawValue) ?? "both" }
        set { defaults.set(newValue, forKey: PrefKey.tokenDisplayCurrency.rawValue) }
    }

    var tokenUSDToCNYRate: Double {
        get { max(defaults.double(forKey: PrefKey.tokenUSDToCNYRate.rawValue), 0.01) }
        set { defaults.set(max(newValue, 0.01), forKey: PrefKey.tokenUSDToCNYRate.rawValue) }
    }

    var enabledTokenSources: Set<TokenSource> {
        get {
            let raw = defaults.stringArray(forKey: PrefKey.enabledTokenTrackers.rawValue) ?? []
            return Set(raw.compactMap(TokenSource.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: PrefKey.enabledTokenTrackers.rawValue)
        }
    }

    var tokenSyncEnabled: Bool {
        get { defaults.bool(forKey: PrefKey.tokenSyncEnabled.rawValue) }
        set { defaults.set(newValue, forKey: PrefKey.tokenSyncEnabled.rawValue) }
    }

    var tokenSyncServerURL: String {
        get { defaults.string(forKey: PrefKey.tokenSyncServerURL.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: PrefKey.tokenSyncServerURL.rawValue) }
    }

    var tokenSyncDeviceID: String {
        get {
            if let value = defaults.string(forKey: PrefKey.tokenSyncDeviceID.rawValue), !value.isEmpty {
                return value
            }
            let value = UUID().uuidString.lowercased()
            defaults.set(value, forKey: PrefKey.tokenSyncDeviceID.rawValue)
            return value
        }
    }

    var tokenSyncDeviceName: String {
        get {
            let value = defaults.string(forKey: PrefKey.tokenSyncDeviceName.rawValue) ?? ""
            return value.isEmpty ? (Host.current().localizedName ?? "Mac") : value
        }
        set { defaults.set(newValue, forKey: PrefKey.tokenSyncDeviceName.rawValue) }
    }
}
