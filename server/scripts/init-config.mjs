import { constants, copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../wrangler.example.jsonc", import.meta.url));
const destination = fileURLToPath(new URL("../wrangler.jsonc", import.meta.url));

try {
  copyFileSync(source, destination, constants.COPYFILE_EXCL);
  console.log("已创建私有配置 server/wrangler.jsonc。");
  console.log("下一步：npm run db:create");
} catch (error) {
  if (error instanceof Error && "code" in error && error.code === "EEXIST") {
    console.log("server/wrangler.jsonc 已存在，为避免覆盖部署配置，本次未修改。");
  } else {
    throw error;
  }
}
