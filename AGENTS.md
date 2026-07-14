# ZFStatMenus 协作约定

## 项目入口

- 总览与部署：`README.md`
- 应用入口：`zfstatmenus/App/ZFStatMenusApp.swift`
- 生命周期：`zfstatmenus/App/AppCoordinator.swift`
- 系统监控：`zfstatmenus/Monitors/`
- 状态栏与弹窗：`zfstatmenus/StatusBar/`
- 设置：`zfstatmenus/Settings/SettingsView.swift`
- Token 模型与定价：`zfstatmenus/Models/TokenUsage.swift`
- Token 采集：`zfstatmenus/TokenTracker/TokenUsageMonitor.swift`
- 本地 SQLite：`zfstatmenus/TokenTracker/TokenUsageStore.swift`
- 多设备同步：`zfstatmenus/TokenTracker/TokenSyncService.swift`
- Worker：`server/src/index.ts`
- D1 迁移：`server/migrations/`

## 通用规则

1. 使用中文思考、配置和回复。
2. 保持最小正确修改，不覆盖或清理用户的无关改动。
3. 不在代码、文档、示例或日志中提交真实 API Key、Bearer Token、D1 ID、个人域名、设备名或本机绝对路径。
4. 生产 `server/wrangler.jsonc` 是被 Git 忽略的私有配置；仓库只维护 `wrangler.example.jsonc` 和 `wrangler.test.jsonc`。
5. `.generated/` 包含临时明文访问 Token，永远不得提交；交付 Token 后应删除。
6. 新增 Swift 文件后运行 `xcodegen generate`。

## 架构约束

- SwiftUI 共享视觉规范位于 `zfstatmenus/DesignSystem/AppTheme.swift`，设置页和弹窗优先复用，并适配浅色/深色。
- 弹窗设置入口统一通过 `SettingsWindowController` 打开或置前同一个窗口。
- Token 缓存使用 `~/Library/Application Support/ZFStatMenus/token-usage-cache.sqlite3`。
- SQLite 使用 `PRAGMA user_version` 顺序迁移；不能破坏已有缓存，schema 变更必须补充迁移和升级测试。
- 本地 SQLite 是同步主数据源：先落库，再异步上传；失败 revision 保留在 `sync_outbox`。
- 明文同步 Token 只能保存在 macOS Keychain。
- Worker 不提供注册/登录接口；用户由管理员生成 SQL 后通过 Wrangler 写入。
- Worker 的所有业务查询必须从 Bearer Token 推导并限定 `user_id`，不能信任客户端提供的用户 ID。
- ZCode `input_tokens` 包含缓存输入，采集时必须扣除缓存读取/写入后分类汇总。
- 同一已知模型统一使用厂商第一方公开 API 单价；无可信单价的内部或订阅型号保持未定价。

## 验证

macOS：

```bash
xcodebuild -project ZFStatMenus.xcodeproj -scheme ZFStatMenus \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Worker：

```bash
cd server
npm ci
npm run check
npm test
```

构建产物统一写入已忽略的 `build/`。未签名打包使用 `./scripts/package.sh`，本机迭代运行使用 `./scripts/build-and-run.sh`。

## Git

- 只有用户明确要求时才提交或推送。
- 提交前查看 `git status`、`git diff` 和最近提交，只暂存本次任务相关文件。
- commit message 使用中文，建议格式：`<类型>: <简要描述>`。
- 不提交环境文件、数据库、日志、构建缓存、生成 Token 或私有 Wrangler 配置。
