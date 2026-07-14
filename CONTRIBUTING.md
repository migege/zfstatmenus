# 参与贡献

感谢你关注 ZFStatMenus。提交改动前，请先搜索已有 Issue，较大的功能建议先创建 Issue 讨论范围和交互。

## 开发环境

- macOS 13 或更高版本
- Xcode 15 或更高版本
- XcodeGen（仅在新增、删除或移动 Swift 文件后需要）
- Node.js 20 或更高版本（仅 Worker）

## 验证

macOS 应用：

```bash
xcodebuild \
  -project ZFStatMenus.xcodeproj \
  -scheme ZFStatMenus \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Cloudflare Worker：

```bash
cd server
npm ci
npm run check
npm test
```

## 提交约定

- 保持改动聚焦，不提交构建产物、数据库、日志、真实 Token、D1 ID、域名或本机路径。
- 数据库结构变更必须新增顺序迁移，并补充升级或持久化测试。
- 新增 Swift 文件后运行 `xcodegen generate` 并提交更新后的工程文件。
- UI 改动应同时适配浅色和深色外观。

提交 Pull Request 时请说明改动目的、验证结果；涉及 UI 时可附去除个人信息后的截图。
