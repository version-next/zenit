/// E2E Test Runner, minimal test framework
///
/// Scheduling contract (shared by the sequential runner and e2e/parallel.ts):
/// - `fatal` tests are preflights: they always run first, and a failure aborts the run.
/// - `final` tests check process-wide invariants accumulated by everything that ran before them
///   in the same app instance; they always run last.
/// - `serial` (a reason string) marks tests whose assertions measure real time or contention
///   (GPU frame-time budgets, frame cadence). The parallel runner gives them a lane of their own
///   that runs while no other instance is alive; the sequential runner runs them in place.
///
/// Environment:
/// - ZENIT_E2E_FILTER="a|b": substring filter (fatal/final tests are always kept).
/// - ZENIT_E2E_LIST=<path>: write the registered tests and their tags as JSON, run nothing.
/// - ZENIT_E2E_PLAN=<path>: JSON array of test names to run, in that order.
/// - ZENIT_E2E_SHUFFLE_SEED=<u32>: run the selected (non-fatal, non-final) tests in a
///   seed-determined random order, to catch tests that depend on state left by earlier ones.
import { mkdirSync, writeFileSync, appendFileSync, readFileSync } from "fs";
import { randomUUID } from "crypto";

type TestFn = () => Promise<void>;

export interface TestOptions {
  /** Preflight: runs first; a failure aborts the remaining tests. */
  fatal?: boolean;
  /** Runs last: asserts an invariant accumulated over the whole instance run. */
  final?: boolean;
  /** Why this test must not share the machine with other instances (timing / contention). */
  serial?: string;
}

interface TestCase {
  name: string;
  fn: TestFn;
  fatal: boolean;
  final: boolean;
  serial: string | null;
}

export interface ListedTest {
  name: string;
  fatal: boolean;
  final: boolean;
  serial: string | null;
}

const tests: TestCase[] = [];
let passed = 0;
let failed = 0;
const failures: { name: string; error: string }[] = [];
const results: { name: string; status: "pass" | "fail"; duration_ms: number }[] = [];

const SESSION_ID = randomUUID().slice(0, 8);
// ZENIT_E2E_SESSION_ROOT: a suite run on the Windows worker keeps its output
// beside the job so the worker can archive it.
const SESSION_DIR = `${process.env.ZENIT_E2E_SESSION_ROOT ?? "/tmp/zenit_e2e_test"}/${SESSION_ID}`;

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

let testOrdinal = 0;
/// Increments when each test starts. Helpers use it to do per-test setup on their first call
/// within a test (see switchTo in storybook.test.ts).
export function currentTestOrdinal(): number {
  return testOrdinal;
}

export function test(name: string, fn: TestFn, options: TestOptions = {}) {
  if (tests.some((t) => t.name === name)) throw new Error(`duplicate test name: ${name}`);
  if (options.serial !== undefined && options.serial.trim() === "") {
    throw new Error(`test "${name}": serial needs a reason`);
  }
  if (options.fatal && (options.final || options.serial !== undefined)) {
    throw new Error(`test "${name}": a fatal preflight cannot also be final or serial`);
  }
  tests.push({
    name,
    fn,
    fatal: options.fatal ?? false,
    final: options.final ?? false,
    serial: options.serial ?? null,
  });
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

/// mulberry32: small, seedable, identical in every JS runtime.
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function shuffled<T>(items: readonly T[], seed: number): T[] {
  const out = items.slice();
  const rand = seededRandom(seed);
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

export function parseSeed(raw: string | undefined): number | null {
  if (raw === undefined || raw.trim() === "") return null;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new Error(`invalid ZENIT_E2E_SHUFFLE_SEED: ${JSON.stringify(raw)} (want an integer 0..4294967295)`);
  }
  return value;
}

/// Fatal preflights first, then `body` in order, then final invariant checks.
function framed(body: TestCase[]): TestCase[] {
  return [
    ...tests.filter((t) => t.fatal),
    ...body.filter((t) => !t.fatal && !t.final),
    ...tests.filter((t) => t.final),
  ];
}

function selectTests(): { selected: TestCase[]; describe: string } {
  const planPath = process.env.ZENIT_E2E_PLAN;
  if (planPath) {
    const names: unknown = JSON.parse(readFileSync(planPath, "utf8"));
    if (!Array.isArray(names) || names.some((n) => typeof n !== "string")) {
      throw new Error(`ZENIT_E2E_PLAN ${planPath}: want a JSON array of test names`);
    }
    const byName = new Map(tests.map((t) => [t.name, t]));
    const unknown = (names as string[]).filter((n) => !byName.has(n));
    if (unknown.length > 0) throw new Error(`ZENIT_E2E_PLAN names unknown tests: ${unknown.join(" | ")}`);
    if (new Set(names).size !== names.length) throw new Error(`ZENIT_E2E_PLAN lists a test twice`);
    // The plan is an exact order; preflights and final checks still frame it.
    return { selected: framed((names as string[]).map((n) => byName.get(n)!)), describe: ` (plan: ${planPath})` };
  }
  const filterTerms = (process.env.ZENIT_E2E_FILTER ?? "")
    .split("|")
    .map((term) => term.trim())
    .filter(Boolean);
  let body = filterTerms.length === 0
    ? tests.slice()
    : tests.filter((t) => !t.fatal && !t.final && filterTerms.some((term) => t.name.includes(term)));
  if (filterTerms.length > 0 && body.length === 0) {
    throw new Error(`ZENIT_E2E_FILTER matched no tests: ${filterTerms.join(" | ")}`);
  }
  let describe = filterTerms.length > 0 ? ` (filter: ${filterTerms.join(" | ")})` : "";
  const seed = parseSeed(process.env.ZENIT_E2E_SHUFFLE_SEED);
  if (seed !== null) {
    body = shuffled(body.filter((t) => !t.fatal && !t.final), seed);
    describe += ` (shuffle seed ${seed})`;
  }
  return { selected: framed(body), describe };
}

export function listTests(): ListedTest[] {
  return tests.map((t) => ({ name: t.name, fatal: t.fatal, final: t.final, serial: t.serial }));
}

export async function run() {
  const listPath = process.env.ZENIT_E2E_LIST;
  if (listPath) {
    writeFileSync(listPath, JSON.stringify(listTests(), null, 2));
    process.exit(0);
  }

  ensureSessionDir();

  const startTime = Date.now();
  const suiteTimeoutMs = Number(process.env.ZENIT_E2E_SUITE_TIMEOUT_MS ?? "900000");
  const deadline = startTime + suiteTimeoutMs;
  const { selected: selectedTests, describe } = selectTests();
  let executed = 0;
  let aborted = 0;
  console.log(`\n  Session: ${SESSION_ID}`);
  console.log(`  Output:  ${SESSION_DIR}`);
  console.log(`  Running ${selectedTests.length}/${tests.length} tests${describe}...\n`);

  appendLog(`# E2E Test Run — ${new Date().toISOString()}`);
  appendLog(`Session: ${SESSION_ID}`);
  appendLog(`Tests: ${selectedTests.length}/${tests.length}${describe}\n`);

  for (const t of selectedTests) {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      failures.push({ name: "suite deadline", error: `suite exceeded ${suiteTimeoutMs}ms` });
      failed++;
      aborted = selectedTests.length - executed;
      break;
    }
    testOrdinal++;
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
      results.push({ name: t.name, status: "pass", duration_ms: dt });
      passed++;
    } catch (e: any) {
      const dt = Date.now() - t0;
      console.log(`\x1b[31mFAIL\x1b[0m (${dt}ms)`);
      console.log(`    ${e.message}\n`);
      appendLog(`FAIL (${dt}ms): ${e.message}`);
      results.push({ name: t.name, status: "fail", duration_ms: dt });
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
    // Per-test outcome in execution order; the parallel runner merges these and
    // records durations for longest-first scheduling.
    order: selectedTests.map((t) => t.name),
    results,
  }, null, 2));
  // A supervisor that runs several instances finds this run's output here.
  if (process.env.ZENIT_E2E_SUMMARY_LINK) {
    writeFileSync(process.env.ZENIT_E2E_SUMMARY_LINK, SESSION_DIR + "\n");
  }

  console.log(`\n  Session output: ${SESSION_DIR}\n`);

  process.exit(failed > 0 ? 1 : 0);
}
