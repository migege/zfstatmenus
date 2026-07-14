# ZFStatMenus 架构设计

本文描述当前实现，用于维护和扩展；用户安装与部署说明以根目录 `README.md` 为准。

## 产品边界

ZFStatMenus 是 macOS 菜单栏应用，核心职责：

- 低开销采集 CPU、内存和网络指标；
- 汇总本机 AI Coding Agent 的 Token 用量；
- 使用 SQLite 增量缓存历史；
- 可选通过自托管 Worker 汇总同一用户的多台设备。

同步关闭时应用完全本地运行。同步服务不接收 Prompt、回复正文、项目名或本地路径。

## 运行时结构

```text
ZFStatMenusApp
└── AppCoordinator
    ├── MonitorManager
    │   ├── CPUMonitor
    │   ├── MemoryMonitor
    │   └── NetworkMonitor
    ├── TokenUsageMonitor
    │   ├── OpenCode / ZCode SQLite 读取
    │   ├── Codex / Claude Code JSONL 解析
    │   ├── TokenUsageStore（本地 SQLite）
    │   └── TokenSyncService（可选）
    └── StatusBarController
        ├── StatusItemView
        ├── PopoverContent
        └── SettingsWindowController
```

## macOS 应用

### 生命周期

- `zfstatmenus/App/ZFStatMenusApp.swift`：SwiftUI 应用入口。
- `zfstatmenus/App/AppCoordinator.swift`：启动监控、状态栏和 Token 刷新。
- 应用设置 `LSUIElement`，不显示 Dock 图标。

### 系统监控

`zfstatmenus/Monitors/` 通过 macOS 系统 API 采集实时指标。`MonitorManager` 按设置中的采样间隔统一调度，并向状态栏发布快照。

### 状态栏与弹窗

`StatusBarController` 为 CPU、内存、网络和 Token 管理独立 `NSStatusItem`。弹窗使用 SwiftUI，视觉组件复用 `DesignSystem/AppTheme.swift`。所有设置入口都由 `SettingsWindowController` 打开同一个设置窗口。

### Token 采集

`TokenUsageMonitor` 负责：

1. 按启用的数据源读取本地数据库或 JSONL；
2. 对 Codex/Claude Code 会话增量解析和去重；
3. 拆分普通输入、缓存读取、缓存写入、输出和推理 Token；
4. 先保存到本地 SQLite，再触发可选同步；
5. 合并本机与远程设备快照供 UI 展示。

模型价格集中在 `Models/TokenUsage.swift`。已知模型采用模型厂商第一方公开单价，不因采集工具或网关 provider 改变；未知型号保持未定价。

## 本地持久化

数据库路径：

```text
~/Library/Application Support/ZFStatMenus/token-usage-cache.sqlite3
```

`TokenUsageStore` 使用 SQLite `PRAGMA user_version` 管理 schema。主要数据包括：

- 每日模型 Token 分类；
- Codex 文件游标和增量缓存；
- 同步元数据；
- 待上传 revision outbox；
- 其他设备的远程日统计缓存。

任何 schema 变更都必须新增顺序迁移，并保留旧缓存升级能力。

## 多设备同步

客户端遵循本地优先：

```text
采集 → 写入本地 SQLite → 记录待同步 revision → 异步上传
                                      ↓
                                失败则保留重试
```

综合视图使用“本机最新本地数据 + 远程缓存中的其他设备”，服务端快照排除当前设备，避免重复统计。访问 Token 明文只保存在 macOS Keychain。

## Cloudflare Worker

入口为 `server/src/index.ts`，D1 schema 位于 `server/migrations/`。

- Token 认证后才能访问业务接口；
- principal 完全从 Bearer Token 推导；
- 所有查询限定 `user_id`；
- 每设备、每日以 revision 幂等替换完整快照；
- 不提供注册、登录或公网 Token 管理接口。

生产 `server/wrangler.jsonc` 是本机私有文件，不进入 Git。仓库中的 `wrangler.example.jsonc` 用于初始化，`wrangler.test.jsonc` 只服务于类型生成和本地测试。

## 验证原则

- Swift 修改至少运行 Xcode scheme 的测试 action。
- Worker 修改运行 `npm run check && npm test`。
- SQLite schema 变更补充迁移和升级测试。
- UI 修改验证浅色/深色、窄内容和滚动行为。
- 发布前扫描真实 Token、D1 ID、域名、本机路径和生成文件。
