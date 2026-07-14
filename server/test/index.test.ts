import { SELF, applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

const token = "zfsm_abcdefghijkl_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq";
const prefix = "abcdefghijkl";
const otherToken = "zfsm_mnopqrstuvwx_QRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567";
const otherPrefix = "mnopqrstuvwx";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM users").run();
  const tokenHash = await sha256Hex(token);
  const otherTokenHash = await sha256Hex(otherToken);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users(id, display_name) VALUES (?, ?)").bind("user-a", "测试用户"),
    env.DB.prepare("INSERT INTO users(id, display_name) VALUES (?, ?)").bind("user-b", "其他用户"),
    env.DB.prepare(
      "INSERT INTO access_tokens(id, user_id, token_prefix, token_hash, label) VALUES (?, ?, ?, ?, ?)",
    ).bind("token-a", "user-a", prefix, tokenHash, "测试 Token"),
    env.DB.prepare(
      "INSERT INTO access_tokens(id, user_id, token_prefix, token_hash, label) VALUES (?, ?, ?, ?, ?)",
    ).bind("token-b", "user-b", otherPrefix, otherTokenHash, "其他 Token"),
  ]);
});

describe("ZFStatMenus sync Worker", () => {
  it("只公开健康检查，其他接口必须认证", async () => {
    const health = await SELF.fetch("https://example.com/v1/health");
    expect(health.status).toBe(200);

    const unauthorized = await SELF.fetch("https://example.com/v1/me");
    expect(unauthorized.status).toBe(401);

    const noLogin = await SELF.fetch("https://example.com/v1/login", {
      method: "POST",
      headers: authorizationHeaders(),
    });
    expect(noLogin.status).toBe(404);
  });

  it("认证 Token 映射到预置用户", async () => {
    const response = await SELF.fetch("https://example.com/v1/me", {
      headers: authorizationHeaders(),
    });
    expect(response.status).toBe(200);
    const body = await response.json<{ user: { id: string; displayName: string } }>();
    expect(body.user).toEqual({ id: "user-a", displayName: "测试用户" });
  });

  it("按 revision 幂等保存每日完整快照并隔离当前设备", async () => {
    await sync("device-a", "Mac A", 1, 100);
    await sync("device-b", "Mac B", 2, 200);

    // 迟到的旧 revision 不得覆盖较新的设备 B 快照。
    await sync("device-b", "Mac B", 1, 50);

    const response = await SELF.fetch(
      "https://example.com/v1/snapshot?from=2026-07-14&to=2026-07-14&excludeDeviceId=device-a",
      { headers: authorizationHeaders() },
    );
    expect(response.status).toBe(200);
    const body = await response.json<{ rows: Array<{ deviceId: string; inputTokens: number }> }>();
    expect(body.rows).toEqual([{
      deviceId: "device-b",
      deviceName: "Mac B",
      day: "2026-07-14",
      source: "codex",
      provider: "openai",
      model: "gpt-5.2-codex",
      inputTokens: 200,
      cachedInputTokens: 0,
      cacheWriteTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
    }]);
  });

  it("不同 Token 所属用户的数据互相不可见", async () => {
    await sync("device-a", "Mac A", 1, 100, token);
    await sync("device-b", "Mac B", 1, 900, otherToken);

    const response = await SELF.fetch(
      "https://example.com/v1/snapshot?from=2026-07-14&to=2026-07-14&excludeDeviceId=unused-device",
      { headers: authorizationHeaders(token) },
    );
    const body = await response.json<{ rows: Array<{ inputTokens: number }> }>();
    expect(body.rows.map((row) => row.inputTokens)).toEqual([100]);
  });

  it("拒绝不存在的日历日期", async () => {
    const response = await SELF.fetch(
      "https://example.com/v1/snapshot?from=2026-02-31&to=2026-03-01&excludeDeviceId=device-a",
      { headers: authorizationHeaders() },
    );
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "invalid_day" },
    });
  });
});

async function sync(
  deviceId: string,
  deviceName: string,
  revision: number,
  inputTokens: number,
  accessToken = token,
): Promise<void> {
  const response = await SELF.fetch("https://example.com/v1/sync", {
    method: "POST",
    headers: {
      ...authorizationHeaders(accessToken),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      schemaVersion: 1,
      device: { id: deviceId, name: deviceName, appVersion: "test" },
      days: [{
        day: "2026-07-14",
        revision,
        usages: [{
          source: "codex",
          provider: "openai",
          model: "gpt-5.2-codex",
          inputTokens,
          cachedInputTokens: 0,
          cacheWriteTokens: 0,
          outputTokens: 0,
          reasoningTokens: 0,
        }],
      }],
    }),
  });
  expect(response.status).toBe(200);
}

function authorizationHeaders(accessToken = token): Record<string, string> {
  return { Authorization: `Bearer ${accessToken}` };
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
