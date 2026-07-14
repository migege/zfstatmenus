# ZFStatMenus 同步服务

基于 Cloudflare Workers + D1 的多用户 Token 汇总服务。它不提供注册、登录、找回密码或公网 Token 管理接口；用户和访问 Token 由服务管理员通过 Wrangler 写入 D1。

## 安全模型

- 除 `GET /v1/health` 外，所有接口都要求 `Authorization: Bearer <Token>`。
- Worker 根据 Token 哈希定位用户，所有业务 SQL 都强制限定 `user_id`。
- 客户端不能上传或指定用户 ID。
- D1 仅保存 Token 前缀和 SHA-256 哈希，不保存明文 Token。
- 上传内容仅包含日期、设备、来源、provider、模型和分类 Token 数。
- 每台设备、每天使用完整快照和单调递增 revision，重试不会重复累计。

## 快速部署

要求 Node.js 22+、Cloudflare 账号。Wrangler 已作为项目开发依赖安装，不需要全局安装。

### 1. 安装与认证

```bash
npm ci
npm run cf:login
npm run cf:whoami
```

### 2. 初始化私有配置和 D1

```bash
npm run config:init
npm run db:create
```

- `config:init` 从 `wrangler.example.jsonc` 创建被 Git 忽略的 `wrangler.jsonc`；已有配置不会被覆盖。
- `db:create` 等价于：

  ```bash
  npx wrangler d1 create zfstatmenus-sync --binding DB --update-config
  ```

  Wrangler 会把新建数据库的 `database_id` 写入私有配置。

### 3. 迁移、检查与部署

```bash
npm run db:migrate:remote
npm run deploy:check
npm run deploy
```

健康检查：

```bash
curl https://<Worker 地址>/v1/health
```

### 4. 创建用户

```bash
npm run user:create -- alice "Alice" "Personal Macs"
npx wrangler d1 execute DB --remote --file .generated/create-user-alice.sql
```

脚本在 `.generated/` 生成：

- `create-user-alice.sql`：用户、Token 哈希和标签；
- `access-token-alice.txt`：明文 Token，仅用于交付给该用户。

文件权限为 `0600`，目录已被 Git 忽略。将 Token 存入密码管理器并完成客户端配置后，应删除临时文件。

## 自定义域名

默认部署会获得 `workers.dev` 地址。若需要自定义域名，在私有 `wrangler.jsonc` 中添加：

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

运行 `npm run deploy`。目标域名必须属于当前 Cloudflare 账号中的活动 Zone，且不能存在冲突的 CNAME。配置文件不会被 Git 跟踪，因此 D1 ID 和个人域名不会进入仓库。

参考：[D1 快速开始](https://developers.cloudflare.com/d1/get-started/)、[D1 迁移](https://developers.cloudflare.com/d1/reference/migrations/)、[Worker Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)。

## 本地开发

生产配置与测试配置相互隔离。单元测试和类型生成使用仓库中的 `wrangler.test.jsonc`，其 D1 ID 是不可部署的全零占位值。

```bash
npm ci
npm run check
npm test
```

本地启动 Worker 前先创建私有配置，然后初始化本地 D1：

```bash
npm run config:init
```

如果私有配置尚无 `DB` binding，可使用已有 D1 信息补充，或执行 `npm run db:create` 创建远程 D1。随后：

```bash
npm run db:migrate:local
npm run dev
```

Wrangler 的本地 D1 状态位于 `.wrangler/`，不会提交。

## 多用户管理

为不同用户重复执行 `user:create`，使用不同用户 ID：

```bash
npm run user:create -- bob "Bob" "Work Macs"
npx wrangler d1 execute DB --remote --file .generated/create-user-bob.sql
```

同一用户可以创建多个 Token；设备使用同一用户下的任意有效 Token 时会看到该用户的汇总。服务端不提供远程创建 Token 的 API。

撤销 Token：

```bash
npx wrangler d1 execute DB --remote --command \
  "UPDATE access_tokens SET revoked_at = CURRENT_TIMESTAMP WHERE id = '<TOKEN_ID>'"
```

执行管理 SQL 前应先通过只读查询确认目标，避免误操作。不要把真实 Token 或导出的 D1 数据提交到 Issue、日志或版本库。

## API

| 方法 | 路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| `GET` | `/v1/health` | 否 | 健康检查与服务器时间 |
| `GET` | `/v1/me` | 是 | 当前用户及设备列表 |
| `POST` | `/v1/sync` | 是 | 幂等写入设备每日完整快照 |
| `GET` | `/v1/snapshot` | 是 | 获取当前用户的远程设备数据 |

## 常用命令

```bash
npm run cf:whoami          # 当前 Cloudflare 身份
npm run deploy:check       # 仅打包校验，不上传
npm run deploy             # 部署 Worker
npm run db:migrate:remote  # 应用远程 D1 迁移
npx wrangler tail          # 查看实时日志
```

如果 `wrangler.jsonc` 丢失，重新运行 `npm run config:init`，再从 `npx wrangler d1 list` 获取数据库信息并恢复 `DB` binding。不要把恢复后的私有配置提交到 Git。
