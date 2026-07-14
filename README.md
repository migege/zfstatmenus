# ZFStatMenus

原生 macOS 菜单栏系统与 AI Coding Token 监控工具。它以紧凑方式展示 CPU、内存、网络和 Token 消耗，并可通过自托管 Cloudflare Worker + D1 汇总多台 Mac。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020?logo=cloudflare&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-2ea44f)

## 功能

- CPU：总体、用户/系统占用、每核活动和高占用进程。
- 内存：已用容量、压力与高占用进程。
- 网络：实时上传/下载速率和近期趋势。
- Token：读取 OpenCode、ZCode、Codex CLI、Claude Code 的本地统计。
- 费用估算：按普通输入、缓存读取、缓存写入、输出/推理 Token 计算公开 API 等价费用。
- 历史视图：今日、过去 7 天、过去 30 天、近一年热力图和来源/模型明细。
- 本地 SQLite 缓存：增量采集，避免每次刷新重新扫描全部历史。
- 可选多设备同步：本地优先、断网补传、按用户隔离，支持多台 Mac 汇总。
- 原生设置页：状态栏栏目、数据源、刷新间隔、汇率和同步配置。

## 数据来源

| 工具 | 默认本地路径 | 读取方式 |
| --- | --- | --- |
| OpenCode | `~/.local/share/opencode/opencode.db` | 只读查询 SQLite |
| ZCode | `~/.zcode/cli/db/db.sqlite` | 读取 `model_usage` |
| Codex CLI | `~/.codex/sessions/` | 增量解析 JSONL |
| Claude Code | `~/.claude/projects/` | 解析 JSONL 并按请求去重 |

ZCode 与 Codex 的输入/输出统计会拆分缓存和推理部分，避免重复计数。缺少可信公开价格的内部型号或订阅别名会显示“未定价”，不会猜价。

## 安装与运行

### 环境要求

- macOS 13.0 或更高版本
- Xcode 15 或更高版本
- XcodeGen（仅修改工程结构时需要）

### 从源码运行

```bash
git clone https://github.com/fly9i/zfstatmenus.git
cd zfstatmenus
./scripts/build-and-run.sh
```

脚本会构建 Debug 应用、关闭正在运行的旧实例，再启动新构建。全量重建可使用：

```bash
./scripts/build-and-run.sh --clean
```

手动构建：

```bash
xcodebuild \
  -project ZFStatMenus.xcodeproj \
  -scheme ZFStatMenus \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

生成未签名 Release ZIP：

```bash
./scripts/package.sh
./scripts/package.sh --arch universal
```

产物位于 `build/packages/`。未签名、未公证的应用仅适合本机开发和测试；首次打开可能需要在系统设置中手动允许。

## 快速部署多设备同步服务

同步服务不是必需组件。只在一台 Mac 上使用时，无需部署 Worker。

服务端使用 Cloudflare Workers + D1，不提供公开注册/登录接口。管理员通过 Wrangler 在 D1 中预置用户和访问 Token，应用只持有对应 Token。

### 前置条件

- Cloudflare 账号；
- Node.js 20 或更高版本；
- 可选：已托管到 Cloudflare 的域名（不配置时直接使用 `workers.dev` 地址）。

### 1. 安装依赖并登录

```bash
cd server
npm ci
npm run cf:login
npm run cf:whoami
```

### 2. 创建私有 Wrangler 配置和 D1

```bash
npm run config:init
npm run db:create
```

`config:init` 从无隐私信息的模板创建 `server/wrangler.jsonc`。该文件已被 Git 忽略。

`db:create` 会创建名为 `zfstatmenus-sync` 的 D1 数据库，并由 Wrangler 自动把 `DB` binding 和 `database_id` 写入私有配置。若 Wrangler 询问是否更新配置，请确认。

### 3. 初始化数据库并部署 Worker

```bash
npm run db:migrate:remote
npm run deploy:check
npm run deploy
```

部署完成后，Wrangler 会输出形如 `https://zfstatmenus-sync.<你的子域>.workers.dev` 的地址。验证健康检查：

```bash
curl https://<你的 Worker 地址>/v1/health
```

### 4. 创建首个用户和访问 Token

下面的 `alice`、`Alice` 和 `Personal Macs` 都是示例，可自行替换：

```bash
npm run user:create -- alice "Alice" "Personal Macs"
npx wrangler d1 execute DB --remote --file .generated/create-user-alice.sql
```

命令会创建两个权限为 `0600` 的本地文件：

- `.generated/create-user-alice.sql`：写入 D1 的 SQL，只包含 Token 哈希；
- `.generated/access-token-alice.txt`：唯一一次保存明文访问 Token。

`.generated/` 已被 Git 忽略。请立即把明文 Token 存入密码管理器，确认应用连接成功后删除这些临时文件。服务端数据库只保存 SHA-256 哈希。

### 5. 配置应用

打开 ZFStatMenus 的“设置 → 同步”，填写：

- 服务器地址：上一步的 Worker URL；
- 访问 Token：`access-token-alice.txt` 中的值；
- 本设备名称：用于区分不同 Mac。

点击“保存并测试”。每台 Mac 使用同一用户的 Token 后，Token 弹窗会显示综合统计和各设备用量。网络不可用时，本机数据和待同步 revision 会继续保存在本地 SQLite。

### 可选：绑定自定义域名

在私有的 `server/wrangler.jsonc` 中增加：

```jsonc
{
  "routes": [
    {
      "pattern": "sync.example.com",
      "custom_domain": true
    }
  ]
}
```

然后再次运行 `npm run deploy`。目标域名必须位于当前 Cloudflare 账号的活动 Zone 中，且不能已有冲突的 CNAME。Cloudflare 会为 Custom Domain 创建所需 DNS 记录和证书。详见 [Cloudflare Custom Domains 文档](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)。

完整的本地开发、用户管理和故障排查见 [server/README.md](server/README.md)。

## 隐私与安全

- 默认只在本机读取 Token 汇总，不上传 Prompt、回复、会话正文、项目名或本地文件路径。
- 同步默认关闭；启用后只上传日期、设备标识、来源、provider、模型和分类 Token 数。
- 本地明文访问 Token 仅保存在 macOS Keychain。
- Worker 由 Bearer Token 推导用户，客户端不能指定或越权查询 `user_id`。
- D1 只保存访问 Token 的 SHA-256 哈希，并支持撤销和过期字段。
- `wrangler.jsonc`、`.generated/`、本地数据库、日志和构建产物均被 Git 忽略。

如发现安全问题，请按 [SECURITY.md](SECURITY.md) 私密报告。

## 本地数据

Token 缓存数据库：

```text
~/Library/Application Support/ZFStatMenus/token-usage-cache.sqlite3
```

数据库使用 `PRAGMA user_version` 顺序迁移。删除该文件会丢失本地历史缓存和待同步状态，但不会删除各 Coding Agent 自身的原始数据。

## API 费用说明

费用是公开标准 API 单价的等价估算，不代表 Codex、Claude Code、Coding Plan 等订阅产品的实际账单。价格集中维护在 `zfstatmenus/Models/TokenUsage.swift` 的 `ModelPricingCatalog`。

估算不包含订阅费、长上下文阶梯、Batch/Priority、工具调用、地区差异和促销。更新价格时应优先核对模型厂商官方页面并同步测试。

## 项目结构

```text
zfstatmenus/          macOS 应用
zfstatmenusTests/     XCTest 测试
server/               Cloudflare Worker、D1 迁移和测试
scripts/              构建、运行和打包脚本
docs/                 架构与设计文档
project.yml           XcodeGen 工程定义
```

关键入口：

- 应用：`zfstatmenus/App/ZFStatMenusApp.swift`
- 生命周期：`zfstatmenus/App/AppCoordinator.swift`
- Token 采集：`zfstatmenus/TokenTracker/TokenUsageMonitor.swift`
- 本地 SQLite：`zfstatmenus/TokenTracker/TokenUsageStore.swift`
- 多设备同步：`zfstatmenus/TokenTracker/TokenSyncService.swift`
- Worker：`server/src/index.ts`
- D1 迁移：`server/migrations/`

## 测试

macOS：

```bash
xcodebuild \
  -project ZFStatMenus.xcodeproj \
  -scheme ZFStatMenus \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Worker：

```bash
cd server
npm ci
npm run check
npm test
```

## 贡献与许可

欢迎提交 Issue 和 Pull Request，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

项目代码使用 [MIT License](LICENSE)。Solar Token 图标使用 CC BY 4.0，署名信息见 [NOTICE](NOTICE)。
