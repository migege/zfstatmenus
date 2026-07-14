import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case statusBar
    case token
    case sync
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .statusBar: return "状态栏"
        case .token: return "Token"
        case .sync: return "同步"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "采样与应用行为"
        case .statusBar: return "栏目与显示方式"
        case .token: return "来源、费用与刷新"
        case .sync: return "多设备数据汇总"
        case .about: return "版本与数据边界"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .statusBar: return "menubar.rectangle"
        case .token: return "dollarsign.circle.fill"
        case .sync: return "arrow.triangle.2.circlepath.icloud"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @AppStorage("monitorInterval") private var monitorInterval = 1.0
    @AppStorage("showSparkline") private var showSparkline = true
    @AppStorage("showValueText") private var showValueText = true
    @State private var selection: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ZFStatMenus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("系统与 Token 监控")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 12)

                VStack(spacing: 4) {
                    ForEach(SettingsPane.allCases) { pane in
                        Button {
                            selection = pane
                        } label: {
                            HStack(spacing: 10) {
                                Group {
                                    if pane == .token {
                                        Image("TokenGlyph")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 14, height: 14)
                                    } else {
                                        Image(systemName: pane.systemImage)
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                }
                                    .foregroundStyle(selection == pane ? AppTheme.accent : .primary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pane.title)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(pane.subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 45)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selection == pane ? AppTheme.accentSoft : Color.clear)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == pane ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                Spacer(minLength: 8)

                Divider()
                Text("版本 0.1.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(AppTheme.sidebar)
            .frame(width: 210)

            Divider().overlay(AppTheme.border)

            Group {
                switch selection {
                case .general:
                    GeneralSettingsView(monitorInterval: $monitorInterval)
                case .statusBar:
                    StatusBarSettingsView(showSparkline: $showSparkline, showValueText: $showValueText)
                case .token:
                    TokenSettingsView()
                case .sync:
                    TokenSyncSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.canvas)
        }
        .frame(width: 790, height: 550)
        .background(AppTheme.canvas)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(AppTheme.pagePadding)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.canvas)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSectionHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
            Divider().overlay(AppTheme.border)
            VStack(spacing: 0) {
                content
            }
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            control
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 15).overlay(AppTheme.border)
    }
}

struct GeneralSettingsView: View {
    @Binding var monitorInterval: Double

    var body: some View {
        SettingsPage(
            title: "通用",
            subtitle: "控制系统指标采样频率与基础运行信息。"
        ) {
            SettingsGroup(title: "实时监控", subtitle: "更短的间隔响应更快，也会增加少量系统开销。") {
                SettingsRow(title: "采样间隔", detail: "CPU、内存与网络刷新频率") {
                    Picker("", selection: $monitorInterval) {
                        Text("1 秒").tag(1.0)
                        Text("2 秒").tag(2.0)
                        Text("5 秒").tag(5.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            SettingsGroup(title: "应用信息") {
                SettingsRow(title: "版本", detail: "当前安装的 ZFStatMenus 版本") {
                    Text("0.1.0")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "运行方式", detail: "常驻菜单栏，不显示 Dock 图标") {
                    AppStatusBadge(title: "菜单栏应用", systemName: "menubar.rectangle")
                }
            }
        }
    }
}

struct StatusBarSettingsView: View {
    @Binding var showSparkline: Bool
    @Binding var showValueText: Bool
    @State private var enabledCPU = true
    @State private var enabledMemory = true
    @State private var enabledNetwork = true
    @State private var enabledToken = false

    var body: some View {
        SettingsPage(
            title: "状态栏",
            subtitle: "选择常驻项目，并控制紧凑指标的显示方式。"
        ) {
            SettingsGroup(title: "显示项目", subtitle: "关闭的项目不会占用菜单栏空间。") {
                StatusItemToggle(title: "CPU", detail: "总使用率与核心活动", icon: .system("cpu"), isOn: $enabledCPU)
                SettingsDivider()
                StatusItemToggle(title: "内存", detail: "已用容量与占用比例", icon: .system("memorychip"), isOn: $enabledMemory)
                SettingsDivider()
                StatusItemToggle(title: "网络", detail: "实时上传与下载速率", icon: .system("arrow.up.arrow.down"), isOn: $enabledNetwork)
                SettingsDivider()
                StatusItemToggle(title: "Token", detail: "今日 AI 编程 Token 消耗", icon: .asset("TokenGlyph"), isOn: $enabledToken)
            }

            SettingsGroup(title: "显示细节") {
                SettingsRow(title: "迷你图表", detail: "在支持的状态项中显示实时走势") {
                    Toggle("", isOn: $showSparkline).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "数值文字", detail: "显示当前容量、速率或 Token 数") {
                    Toggle("", isOn: $showValueText).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { loadPrefs() }
        .onChange(of: enabledCPU) { _ in savePrefs() }
        .onChange(of: enabledMemory) { _ in savePrefs() }
        .onChange(of: enabledNetwork) { _ in savePrefs() }
        .onChange(of: enabledToken) { _ in savePrefs() }
    }

    private func loadPrefs() {
        let items = AppPreferences.shared.enabledStatusItems
        enabledCPU = items.contains(.cpu)
        enabledMemory = items.contains(.memory)
        enabledNetwork = items.contains(.network)
        enabledToken = items.contains(.token)
    }

    private func savePrefs() {
        var items: Set<StatusItemType> = []
        if enabledCPU { items.insert(.cpu) }
        if enabledMemory { items.insert(.memory) }
        if enabledNetwork { items.insert(.network) }
        if enabledToken { items.insert(.token) }
        AppPreferences.shared.enabledStatusItems = items
    }
}

private enum StatusItemIcon {
    case system(String)
    case asset(String)
}

private struct StatusItemToggle: View {
    let title: String
    let detail: String
    let icon: StatusItemIcon
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 12) {
                Group {
                    switch icon {
                    case let .system(name):
                        Image(systemName: name)
                    case let .asset(name):
                        Image(name)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
                .foregroundStyle(isOn ? AppTheme.accent : .secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

struct TokenSettingsView: View {
    @AppStorage("tokenRefreshInterval") private var tokenRefreshInterval = 60.0
    @AppStorage("tokenDisplayCurrency") private var currency = "both"
    @AppStorage("tokenUSDToCNYRate") private var usdToCNYRate = 7.2
    @State private var openCodeEnabled = true
    @State private var zcodeEnabled = true
    @State private var codexEnabled = true
    @State private var claudeEnabled = true

    var body: some View {
        SettingsPage(
            title: "Token",
            subtitle: "管理本地数据来源、刷新节奏和 API 等价费用显示。"
        ) {
            SettingsGroup(title: "统计来源", subtitle: "只读取各工具保存在本机的统计数据。") {
                SourceToggle(title: "OpenCode", path: "~/.local/share/opencode/opencode.db", isOn: $openCodeEnabled)
                SettingsDivider()
                SourceToggle(title: "ZCode", path: "~/.zcode/cli/db/db.sqlite", isOn: $zcodeEnabled)
                SettingsDivider()
                SourceToggle(title: "Codex CLI", path: "~/.codex/sessions/", isOn: $codexEnabled)
                SettingsDivider()
                SourceToggle(title: "Claude Code", path: "~/.claude/projects/", isOn: $claudeEnabled)
            }

            SettingsGroup(title: "刷新与费用") {
                SettingsRow(title: "Token 刷新", detail: "扫描新增和变更的本地记录") {
                    Picker("", selection: $tokenRefreshInterval) {
                        Text("30 秒").tag(30.0)
                        Text("1 分钟").tag(60.0)
                        Text("5 分钟").tag(300.0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "显示币种", detail: "模型费用按照第一方公开 API 单价估算") {
                    Picker("", selection: $currency) {
                        Text("USD + CNY").tag("both")
                        Text("仅 USD").tag("usd")
                        Text("仅 CNY").tag("cny")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsDivider()
                SettingsRow(title: "USD/CNY 汇率", detail: "仅用于把美元价格换算为人民币") {
                    TextField("7.20", value: $usdToCNYRate, format: .number.precision(.fractionLength(2...4)))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }

            Label("费用是标准 API 等价估算，不代表订阅服务的实际扣费。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .onAppear { loadSources() }
        .onChange(of: openCodeEnabled) { _ in saveSources() }
        .onChange(of: zcodeEnabled) { _ in saveSources() }
        .onChange(of: codexEnabled) { _ in saveSources() }
        .onChange(of: claudeEnabled) { _ in saveSources() }
    }

    private func loadSources() {
        let sources = AppPreferences.shared.enabledTokenSources
        openCodeEnabled = sources.contains(.opencode)
        zcodeEnabled = sources.contains(.zcode)
        codexEnabled = sources.contains(.codex)
        claudeEnabled = sources.contains(.claude)
    }

    private func saveSources() {
        var sources: Set<TokenSource> = []
        if openCodeEnabled { sources.insert(.opencode) }
        if zcodeEnabled { sources.insert(.zcode) }
        if codexEnabled { sources.insert(.codex) }
        if claudeEnabled { sources.insert(.claude) }
        AppPreferences.shared.enabledTokenSources = sources
    }
}

private struct SourceToggle: View {
    let title: String
    let path: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: path) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct TokenSyncSettingsView: View {
    @ObservedObject private var syncService = TokenSyncService.shared
    @State private var enabled = false
    @State private var serverURL = ""
    @State private var deviceName = ""
    @State private var token = ""
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        SettingsPage(
            title: "多设备同步",
            subtitle: "汇总多台 Mac 的 Token 统计；网络不可用时继续保存在本地。"
        ) {
            syncStatusPanel

            SettingsGroup(title: "连接配置", subtitle: "Token 由服务管理员提供，并安全保存在本机 Keychain。") {
                SettingsRow(title: "启用同步", detail: "刷新本地统计后自动上传并拉取其他设备") {
                    Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(title: "服务器地址") {
                    TextField("https://sync.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                SettingsDivider()
                SettingsRow(title: "访问 Token") {
                    SecureField(syncService.hasStoredToken ? "已安全保存，留空保持不变" : "zfsm_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                SettingsDivider()
                SettingsRow(title: "本设备名称", detail: "用于区分不同设备上传的数据") {
                    TextField("MacBook Pro", text: $deviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                }
            }

            if let feedback {
                Label(feedback, systemImage: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(feedbackIsError ? AppTheme.danger : AppTheme.success)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("保存") { saveConfiguration(verifyAfterSave: false) }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("保存并测试") { saveConfiguration(verifyAfterSave: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
            }
        }
        .onAppear { loadConfiguration() }
    }

    private var syncStatusPanel: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(syncStatusColor.opacity(0.12))
                TokenSyncStatusSymbol(status: syncService.status)
                    .scaleEffect(1.2)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(syncService.status.message)
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 8) {
                    if syncService.status.pendingDays > 0 {
                        Text("待同步 \(syncService.status.pendingDays) 天")
                    }
                    if let date = syncService.status.lastSuccessAt {
                        Text("上次成功 \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text(enabled ? "尚未完成首次同步" : "本地统计不受影响")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            AppStatusBadge(title: enabled ? "已启用" : "未启用", systemName: enabled ? "icloud.fill" : "icloud.slash", color: syncStatusColor)
        }
        .appPanel(padding: 15)
    }

    private var syncStatusColor: Color {
        switch syncService.status.phase {
        case .disabled: return .secondary
        case .syncing, .pending: return AppTheme.accent
        case .synced: return AppTheme.success
        case .failed: return AppTheme.danger
        }
    }

    private func loadConfiguration() {
        let prefs = AppPreferences.shared
        enabled = prefs.tokenSyncEnabled
        serverURL = prefs.tokenSyncServerURL
        deviceName = prefs.tokenSyncDeviceName
    }

    private func saveConfiguration(verifyAfterSave: Bool) {
        do {
            try syncService.saveConfiguration(
                enabled: enabled,
                serverURL: serverURL,
                deviceName: deviceName,
                newToken: token.isEmpty ? nil : token
            )
            token = ""
            feedback = verifyAfterSave ? "配置已保存，正在验证连接…" : "配置已保存"
            feedbackIsError = false
            guard verifyAfterSave, enabled else { return }
            syncService.verifyConnection { result in
                switch result {
                case .success(let user):
                    feedback = "认证成功：\(user)"
                    feedbackIsError = false
                case .failure(let error):
                    feedback = error.localizedDescription
                    feedbackIsError = true
                }
            }
        } catch {
            feedback = error.localizedDescription
            feedbackIsError = true
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(
            title: "关于",
            subtitle: "ZFStatMenus 在菜单栏集中展示系统状态与 AI 编程 Token 消耗。"
        ) {
            HStack(alignment: .top, spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .accessibilityLabel("ZFStatMenus 应用图标")

                VStack(alignment: .leading, spacing: 7) {
                    Text("ZFStatMenus")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.4)
                    Text("版本 0.1.0（1）")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("原生 macOS 菜单栏监控工具")
                        .font(.system(size: 13, weight: .medium))
                    Text("系统指标始终在本机处理。只有主动启用自托管同步后，应用才会上传按日期和模型汇总的 Token 数量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 370, alignment: .leading)
                }
                Spacer()
            }
            .appPanel(padding: 18)

            SettingsGroup(title: "数据边界") {
                SettingsRow(title: "系统监控", detail: "CPU、内存、网络数据仅保留在当前进程") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.success)
                }
                SettingsDivider()
                SettingsRow(title: "Token 统计", detail: "不读取或上传 Prompt、会话正文和项目内容") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.success)
                }
                SettingsDivider()
                SettingsRow(title: "同步服务", detail: "可选、自托管，并使用独立访问 Token") {
                    Image(systemName: "lock.fill").foregroundStyle(AppTheme.accent)
                }
            }

            Text("© 2026 ZFStatMenus")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct TokenSyncStatusSymbol: View {
    let status: TokenSyncStatus

    var body: some View {
        Group {
            if status.phase == .syncing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(color)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(status.message)
    }

    private var iconName: String {
        switch status.phase {
        case .disabled: return "icloud.slash"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.icloud.fill"
        case .pending: return "icloud.and.arrow.up"
        case .failed: return "exclamationmark.icloud.fill"
        }
    }

    private var color: Color {
        switch status.phase {
        case .disabled: return .secondary
        case .syncing, .pending: return AppTheme.accent
        case .synced: return AppTheme.success
        case .failed: return AppTheme.danger
        }
    }
}
