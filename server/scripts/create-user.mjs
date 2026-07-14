import { createHash, randomBytes, randomUUID } from "node:crypto";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [userId, displayName, tokenLabel = "默认 Token"] = process.argv.slice(2);

if (!userId || !/^[A-Za-z0-9_-]{1,64}$/.test(userId)) {
  console.error("用法：npm run user:create -- <用户ID> <显示名称> [Token 标签]");
  console.error("用户 ID 只允许字母、数字、下划线和连字符，最长 64 字符。");
  process.exit(1);
}

if (!displayName || displayName.length > 100) {
  console.error("显示名称不能为空且不能超过 100 字符。");
  process.exit(1);
}

const secret = randomBytes(32).toString("base64url");
const prefix = secret.slice(0, 12);
const token = `zfsm_${prefix}_${secret}`;
const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");
const tokenId = randomUUID();

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;
const sql = [
  "PRAGMA foreign_keys = ON;",
  `INSERT INTO users(id, display_name, active) VALUES (${quote(userId)}, ${quote(displayName)}, 1)`,
  "ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name, active = 1, updated_at = CURRENT_TIMESTAMP;",
  `INSERT INTO access_tokens(id, user_id, token_prefix, token_hash, label) VALUES (${quote(tokenId)}, ${quote(userId)}, ${quote(prefix)}, ${quote(tokenHash)}, ${quote(tokenLabel)});`,
  "",
].join("\n");

const outputDirectory = resolve(".generated");
const outputPath = resolve(outputDirectory, `create-user-${userId}.sql`);
const tokenOutputPath = resolve(outputDirectory, `access-token-${userId}.txt`);
mkdirSync(outputDirectory, { recursive: true });
writeFileSync(outputPath, sql, { encoding: "utf8", mode: 0o600 });
chmodSync(outputPath, 0o600);
writeFileSync(tokenOutputPath, `${token}\n`, { encoding: "utf8", mode: 0o600 });
chmodSync(tokenOutputPath, 0o600);

console.log(`用户：${userId}（${displayName}）`);
console.log(`访问 Token 文件：${tokenOutputPath}`);
console.log(`D1 SQL：${outputPath}`);
console.log("请把 Token 文件中的值保存到密码管理器；D1 中只会写入 SHA-256 哈希。\n");
console.log(`执行到远程 D1：npx wrangler d1 execute DB --remote --file ${outputPath}`);
