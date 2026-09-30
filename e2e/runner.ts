/// E2E Test Runner — 极简测试框架
import { mkdirSync, writeFileSync, appendFileSync } from "fs";
import { randomUUID } from "crypto";

type TestFn = () => Promise<void>;

interface TestCase {
  name: string;
  fn: TestFn;
  fatal: boolean;
}

const tests: TestCase[] = [];
let passed = 0;
let failed = 0;
const failures: { name: string; error: string }[] = [];

const SESSION_ID = randomUUID().slice(0, 8);
const SESSION_DIR = `/tmp/zenit_e2e_test/${SESSION_ID}`;

function ensureSessionDir(): void {
  mkdirSync(SESSION_DIR, { recursive: true });
}

export function getSessionDir(): string {
  ensureSessionDir();
  return SESSION_DIR;
}

export function writeSessionFile(filename: string, content: string): string {
  ensureSessionDir();
  const path = `${SESSION_DIR}/${filename}`;
  writeFileSync(path, content);
  return path;
}

export function appendLog(line: string): void {
  ensureSessionDir();
  appendFileSync(`${SESSION_DIR}/test.log`, line + "\n");
}

export function test(name: string, fn: TestFn, options: { fatal?: boolean } = {}) {
  tests.push({ name, fn, fatal: options.fatal ?? false });
}

export function assert(condition: boolean, msg = "assertion failed") {
  if (!condition) throw new Error(msg);
}

export function assertEqual<T>(actual: T, expected: T, msg?: string) {
  if (actual !== expected) {
    throw new Error(
      msg || `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

export function assertContains(haystack: string, needle: string, msg?: string) {
  if (!haystack.includes(needle)) {
    throw new Error(msg || `expected "${haystack}" to contain "${needle}"`);
  }
}

export async function run() {
  ensureSessionDir();

  const startTime = Date.now();
  const suiteTimeoutMs = Number(process.env.ZENIT_E2E_SUITE_TIMEOUT_MS ?? "900000");
  const deadline = startTime + suiteTimeoutMs;
  const filterTerms = (process.env.ZENIT_E2E_FILTER ?? "")
    .split("|")
    .map((term) => term.trim())
    .filter(Boolean);
  const selectedTests = filterTerms.length === 0
    ? tests
    : tests.filter((t) => t.fatal || filterTerms.some((term) => t.name.includes(term)));
  if (filterTerms.length > 0 && selectedTests.every((t) => t.fatal)) {
    throw new Error(`ZENIT_E2E_FILTER matched no tests: ${filterTerms.join(" | ")}`);
  }
  let executed = 0;
  let aborted = 0;
  console.log(`\n  Session: ${SESSION_ID}`);
  console.log(`  Output:  ${SESSION_DIR}`);
  console.log(`  Running ${selectedTests.length}/${tests.length} tests${filterTerms.length > 0 ? ` (filter: ${filterTerms.join(" | ")})` : ""}...\n`);

  appendLog(`# E2E Test Run — ${new Date().toISOString()}`);
  appendLog(`Session: ${SESSION_ID}`);
  appendLog(`Tests: ${selectedTests.length}/${tests.length}\n`);

  for (const t of selectedTests) {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      failures.push({ name: "suite deadline", error: `suite exceeded ${suiteTimeoutMs}ms` });
      failed++;
      aborted = selectedTests.length - executed;
      break;
    }
    process.stdout.write(`  ${t.name} ... `);
    appendLog(`--- ${t.name} ---`);
    const t0 = Date.now();
    try {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        await Promise.race([
          t.fn(),
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(new Error(`suite deadline exceeded after ${suiteTimeoutMs}ms`)),
              remainingMs,
            );
          }),
        ]);
      } finally {
        if (timer !== undefined) clearTimeout(timer);
      }
      const dt = Date.now() - t0;
      console.log(`\x1b[32mPASS\x1b[0m (${dt}ms)`);
      appendLog(`PASS (${dt}ms)`);
      passed++;
    } catch (e: any) {
      const dt = Date.now() - t0;
      console.log(`\x1b[31mFAIL\x1b[0m (${dt}ms)`);
      console.log(`    ${e.message}\n`);
      appendLog(`FAIL (${dt}ms): ${e.message}`);
      failures.push({ name: t.name, error: e.message });
      failed++;
      executed++;
      if (t.fatal || Date.now() >= deadline) {
        aborted = selectedTests.length - executed;
        appendLog(`ABORT: ${aborted} tests not run after fatal preflight/deadline failure`);
        break;
      }
      continue;
    }
    executed++;
  }

  const totalMs = Date.now() - startTime;
  console.log(`\n  Results: ${passed} passed, ${failed} failed, ${aborted} aborted (${totalMs}ms)`);
  appendLog(`\nResults: ${passed} passed, ${failed} failed, ${aborted} aborted (${totalMs}ms)`);

  if (failures.length > 0) {
    console.log("\n  Failures:");
    for (const f of failures) {
      console.log(`    - ${f.name}: ${f.error}`);
    }
  }

  writeSessionFile("summary.json", JSON.stringify({
    session_id: SESSION_ID,
    timestamp: new Date().toISOString(),
    total: selectedTests.length,
    executed,
    passed,
    failed,
    aborted,
    duration_ms: totalMs,
    failures,
  }, null, 2));

  console.log(`\n  Session output: ${SESSION_DIR}\n`);

  process.exit(failed > 0 ? 1 : 0);
}
