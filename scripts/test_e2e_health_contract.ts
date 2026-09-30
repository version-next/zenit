import { mkdtemp, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getE2eTimeoutMs, health, sleep, waitFor } from "../e2e/client";

async function waitForRequest(dir: string): Promise<{ id: string; path: string }> {
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline) {
    const name = (await readdir(dir)).find((entry) => /^req-.+\.json$/.test(entry));
    if (name) return { id: name.slice(4, -5), path: join(dir, name) };
    await sleep(5);
  }
  throw new Error("health contract: client did not publish a request");
}

async function expectRejected(promise: Promise<unknown>, pattern: RegExp): Promise<void> {
  try {
    await promise;
  } catch (err: any) {
    if (pattern.test(String(err?.message ?? err))) return;
    throw new Error(`health contract: wrong rejection: ${err?.message ?? err}`);
  }
  throw new Error("health contract: expected request to fail closed");
}

const dir = await mkdtemp(join(tmpdir(), "zenit-health-contract-"));
process.env.ZENIT_E2E_FILE_RPC_DIR = dir;
process.env.ZENIT_E2E_TIMEOUT_MS = "1000";

try {
  if (getE2eTimeoutMs(6000) !== 6000) {
    throw new Error("timeout contract: call-site minimum must win over a smaller configured timeout");
  }
  process.env.ZENIT_E2E_TIMEOUT_MS = "30000";
  if (getE2eTimeoutMs(6000) !== 30000) {
    throw new Error("timeout contract: CI timeout must propagate to higher-level waits");
  }
  process.env.ZENIT_E2E_TIMEOUT_MS = "invalid";
  try {
    getE2eTimeoutMs();
    throw new Error("timeout contract: invalid timeout unexpectedly accepted");
  } catch (err: any) {
    if (!/invalid ZENIT_E2E_TIMEOUT_MS/.test(String(err?.message ?? err))) throw err;
  }
  await expectRejected(health(), /invalid ZENIT_E2E_TIMEOUT_MS/);
  if ((await readdir(dir)).some((entry) => /^req-.+\.json$/.test(entry))) {
    throw new Error("timeout contract: invalid configuration published an orphan request");
  }
  process.env.ZENIT_E2E_TIMEOUT_MS = "1000";

  await expectRejected(
    waitFor(async () => { throw new Error("probe failure"); }, 5, 1),
    /waitFor timeout.*last error: probe failure/,
  );

  // A response that becomes visible before its JSON is complete must be a
  // protocol failure, never a synthetic `{raw: ...}` health result.
  const malformed = health();
  const malformedReq = await waitForRequest(dir);
  await writeFile(join(dir, `res-${malformedReq.id}.json`), '{"status":', "utf8");
  await expectRejected(malformed, /malformed file-RPC response/);

  // The server contract writes privately and publishes with rename. The
  // client must observe the complete message and accept its exact schema.
  const healthy = health();
  const healthyReq = await waitForRequest(dir);
  const tmp = join(dir, `res-${healthyReq.id}.tmp`);
  await writeFile(tmp, '{"status":"ok"}', "utf8");
  await rename(tmp, join(dir, `res-${healthyReq.id}.json`));
  const result = await healthy;
  if (result.status !== "ok") throw new Error(`health contract: unexpected result ${JSON.stringify(result)}`);

  // Valid JSON with the wrong schema is also fail-closed. This catches stale
  // or cross-request results such as a prior screenshot's `{ "ok": true }`.
  const wrongSchema = health();
  const schemaReq = await waitForRequest(dir);
  await writeFile(join(dir, `res-${schemaReq.id}.json`), '{"ok":true}', "utf8");
  await expectRejected(wrongSchema, /invalid health response/);

  console.log("file-RPC health atomic publication + fail-closed schema: PASS");
} finally {
  await rm(dir, { recursive: true, force: true });
}
