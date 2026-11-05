/// Parallel storybook e2e supervisor: N app instances, one build, merged result.
///
/// Entry point: `bash scripts/run_storybook_e2e_parallel.sh` (builds once, then runs this).
/// Every shard is one `scripts/run_storybook_e2e.sh` unit with ZENIT_E2E_SKIP_BUILD=1, so each
/// instance keeps the sequential gate's supervision unchanged: its own fresh RPC dir, app log,
/// evidence dir, manifest and session dir, the "app died -> exit 86" watchdog, the exit-time
/// leak gate and the fatal preflight (the runner always runs `fatal` tests first).
///
/// Scheduling:
/// - `fatal` and `final` tests (see e2e/runner.ts) run on every instance.
/// - `serial` tests run in a lane of their own after every parallel instance has exited, so a
///   timing gate never shares the machine with another instance.
/// - Everything else is split across instances longest-processing-time first, from durations
///   recorded by earlier runs (ZENIT_E2E_DURATIONS), falling back to the committed estimate
///   e2e/<suite>.durations.json and then to DEFAULT_ESTIMATE_MS.
///
/// Environment (all optional):
/// - ZENIT_E2E_JOBS: instance count, or "auto" (default) = clamp(cpus / 2, 2, 8).
/// - ZENIT_E2E_SHUFFLE_SEED: shuffle each instance's order (seed-derived per instance); the
///   effective per-instance seeds and plans are written to the output dir for replay.
/// - ZENIT_E2E_FILTER: same substring filter as the sequential runner.
/// - ZENIT_E2E_OUT: output root (default /tmp/zenit_e2e_parallel/<timestamp>).
/// - ZENIT_E2E_MANIFEST: merged manifest path (default <out>/manifest.json).
/// - ZENIT_E2E_TEST_FILE, ZENIT_E2E_APP, ZENIT_E2E_BUN: passed through to every shard.
import { spawn, spawnSync } from "node:child_process";
import { availableParallelism } from "node:os";
import { existsSync, mkdirSync, readFileSync, writeFileSync, createWriteStream, renameSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { parseSeed, shuffled, type ListedTest } from "./runner";

const DEFAULT_ESTIMATE_MS = 2000;
// Port numbers only name the per-instance RPC dir (the harness has no socket).
const BASE_PORT = 19900;

const repo = resolve(import.meta.dir, "..");
const testFile = process.env.ZENIT_E2E_TEST_FILE ?? "e2e/storybook.test.ts";
const suite = basename(testFile).replace(/\.test\.ts$/, "").replace(/\.ts$/, "");
const outRoot = resolve(process.env.ZENIT_E2E_OUT ?? `/tmp/zenit_e2e_parallel/${new Date().toISOString().replace(/[:.]/g, "-")}`);
const durationsPath = process.env.ZENIT_E2E_DURATIONS ?? join(homedir(), "Library/Caches/zenit-e2e", `${suite}.durations.json`);
const baselinePath = join(repo, "e2e", `${suite}.durations.json`);
const manifestPath = process.env.ZENIT_E2E_MANIFEST ?? join(outRoot, "manifest.json");

function jobCount(): number {
  const raw = (process.env.ZENIT_E2E_JOBS ?? "auto").trim();
  if (raw === "" || raw === "auto") return Math.min(8, Math.max(2, Math.floor(availableParallelism() / 2)));
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 64) throw new Error(`invalid ZENIT_E2E_JOBS: ${JSON.stringify(raw)}`);
  return n;
}

function readJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

function listTests(): ListedTest[] {
  const listPath = join(outRoot, "tests.json");
  const res = spawnSync(process.execPath, [testFile], {
    cwd: repo,
    env: { ...process.env, ZENIT_E2E_LIST: listPath, ZENIT_E2E_SESSION_ROOT: join(outRoot, "list-session") },
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (res.status !== 0) throw new Error(`listing ${testFile} failed (rc=${res.status})`);
  return JSON.parse(readFileSync(listPath, "utf8"));
}

function selectByFilter(all: ListedTest[]): ListedTest[] {
  const terms = (process.env.ZENIT_E2E_FILTER ?? "").split("|").map((t) => t.trim()).filter(Boolean);
  if (terms.length === 0) return all.filter((t) => !t.fatal && !t.final);
  const picked = all.filter((t) => !t.fatal && !t.final && terms.some((term) => t.name.includes(term)));
  if (picked.length === 0) throw new Error(`ZENIT_E2E_FILTER matched no tests: ${terms.join(" | ")}`);
  return picked;
}

/// Longest processing time first: each test goes to the currently least-loaded instance.
/// Within an instance the registration order is kept (or shuffled with a seed).
export function partition(tests: ListedTest[], jobs: number, estimate: (name: string) => number): ListedTest[][] {
  const order = new Map(tests.map((t, i) => [t.name, i]));
  const sorted = tests.slice().sort((a, b) => estimate(b.name) - estimate(a.name) || order.get(a.name)! - order.get(b.name)!);
  const bins = Array.from({ length: jobs }, () => ({ load: 0, tests: [] as ListedTest[] }));
  for (const t of sorted) {
    let best = bins[0];
    for (const bin of bins) if (bin.load < best.load) best = bin;
    best.tests.push(t);
    best.load += estimate(t.name);
  }
  return bins.map((bin) => bin.tests.sort((a, b) => order.get(a.name)! - order.get(b.name)!));
}

interface ShardResult {
  label: string;
  index: number;
  rc: number;
  failureKind: string;
  planned: string[];
  sessionDir: string | null;
  summary: any | null;
  wallMs: number;
}

// Supervisors still running; a signal to this process is forwarded so each shard runs its own
// cleanup (stop app + runner, copy evidence, write its manifest).
const live = new Set<ReturnType<typeof spawn>>();
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    for (const child of live) child.kill("SIGTERM");
    console.error(`\n${sig}: stopping ${live.size} instance(s)`);
    setTimeout(() => process.exit(130), 5000).unref();
  });
}

function runShard(label: string, index: number, plan: string[], port: number): Promise<ShardResult> {
  const dir = join(outRoot, label);
  mkdirSync(dir, { recursive: true });
  const planPath = join(dir, "plan.json");
  writeFileSync(planPath, JSON.stringify(plan, null, 2));
  const link = join(dir, "session-dir.txt");
  const env: Record<string, string | undefined> = {
    ...process.env,
    ZENIT_E2E_SKIP_BUILD: "1",
    // Parallel instances never activate, take key focus or order windows front; every input
    // arrives through the harness RPC.
    ZENIT_E2E_BACKGROUND: "1",
    ZENIT_E2E_ISOLATE_POINTER: "1",
    ZENIT_E2E_ISOLATE_KEYBOARD: "1",
    ZENIT_E2E_PORT: String(port),
    ZENIT_E2E_APP_LOG: join(dir, "app.log"),
    ZENIT_E2E_EVIDENCE_DIR: join(dir, "evidence"),
    ZENIT_E2E_MANIFEST: join(dir, "evidence", "manifest.json"),
    ZENIT_E2E_SESSION_ROOT: join(dir, "session"),
    ZENIT_E2E_SUMMARY_LINK: link,
    ZENIT_E2E_PLAN: planPath,
    ZENIT_E2E_TEST_FILE: testFile,
  };
  delete env.ZENIT_E2E_FILE_RPC_DIR; // each shard makes its own fresh dir
  delete env.ZENIT_E2E_FILTER; // the plan is exact
  delete env.ZENIT_E2E_SHUFFLE_SEED; // already applied to the plan
  delete env.ZENIT_E2E_PASTEBOARD; // run_storybook_e2e.sh names one per instance
  const started = Date.now();
  const console_ = createWriteStream(join(dir, "console.log"));
  return new Promise((resolveShard) => {
    const child = spawn("bash", ["scripts/run_storybook_e2e.sh"], { cwd: repo, env, stdio: ["ignore", "pipe", "pipe"] });
    live.add(child);
    child.stdout.pipe(console_, { end: false });
    child.stderr.pipe(console_, { end: false });
    child.on("close", (code, signal) => {
      live.delete(child);
      console_.end();
      const rc = code ?? (signal ? 128 : 1);
      const manifest = readJson<any>(join(dir, "evidence", "manifest.json"), null);
      const sessionDir = existsSync(link) ? readFileSync(link, "utf8").trim() : null;
      const summary = sessionDir ? readJson<any>(join(sessionDir, "summary.json"), null) : null;
      resolveShard({
        label,
        index,
        rc,
        failureKind: manifest?.failure_kind ?? (rc === 0 ? "none" : "unknown"),
        planned: plan,
        sessionDir,
        summary,
        wallMs: Date.now() - started,
      });
    });
  });
}

/// Same precedence a reader of the sequential gate expects: a dead app (86) or an exit-time
/// leak (87) outranks an ordinary assertion failure.
export function mergedExitCode(codes: number[]): number {
  for (const special of [86, 87]) if (codes.includes(special)) return special;
  return codes.find((c) => c !== 0) ?? 0;
}

function report(r: ShardResult): string {
  const s = r.summary;
  const counts = s ? `${s.passed} passed, ${s.failed} failed, ${s.aborted} aborted` : "no summary";
  return `${r.label}: rc=${r.rc} ${counts} in ${(r.wallMs / 1000).toFixed(1)}s (${r.failureKind})`;
}

async function main() {
  mkdirSync(outRoot, { recursive: true });
  const t0 = Date.now();
  const all = listTests();
  const selected = selectByFilter(all);
  const parallelTests = selected.filter((t) => t.serial === null);
  const serialTests = selected.filter((t) => t.serial !== null);
  const seed = parseSeed(process.env.ZENIT_E2E_SHUFFLE_SEED);

  const recorded = readJson<Record<string, number>>(durationsPath, {});
  const baseline = readJson<Record<string, number>>(baselinePath, {});
  const estimate = (name: string) => recorded[name] ?? baseline[name] ?? DEFAULT_ESTIMATE_MS;
  const jobs = Math.max(1, Math.min(jobCount(), parallelTests.length));
  const bins = parallelTests.length > 0 ? partition(parallelTests, jobs, estimate) : [];
  const plans = bins.map((bin, i) => {
    const names = bin.map((t) => t.name);
    return seed === null ? names : shuffled(names, (seed + Math.imul(i + 1, 0x9e3779b1)) >>> 0);
  });
  const serialPlan = (() => {
    const names = serialTests.map((t) => t.name);
    return seed === null ? names : shuffled(names, (seed ^ 0x5e1a1) >>> 0);
  })();

  writeFileSync(join(outRoot, "schedule.json"), JSON.stringify({
    jobs, seed, durations: durationsPath,
    shards: plans.map((p, i) => ({ label: `shard-${i}`, estimate_ms: p.reduce((a, n) => a + estimate(n), 0), tests: p })),
    serial: serialPlan,
  }, null, 2));
  console.log(`==> ${selected.length} tests (+ preflight/final checks on every instance): ${parallelTests.length} across ${jobs} instances, ${serialTests.length} in the serial lane${seed === null ? "" : `, shuffle seed ${seed}`}`);
  plans.forEach((p, i) => console.log(`    shard-${i}: ${p.length} tests, ~${Math.round(p.reduce((a, n) => a + estimate(n), 0) / 1000)}s estimated`));
  console.log(`    output: ${outRoot}`);

  const shardResults = await Promise.all(plans.map((plan, i) => {
    return runShard(`shard-${i}`, i, plan, BASE_PORT + i).then((r) => { console.log(`  ${report(r)}`); return r; });
  }));
  const parallelMs = Date.now() - t0;

  let serialResult: ShardResult | null = null;
  if (serialPlan.length > 0) {
    // No other instance is alive at this point: every shard promise has settled, and each
    // shard's supervisor waits for its app before it exits.
    console.log(`==> serial lane: ${serialPlan.length} tests on a quiet instance`);
    serialResult = await runShard("serial", jobs, serialPlan, BASE_PORT + jobs);
    console.log(`  ${report(serialResult)}`);
  }

  const lanes = serialResult ? [...shardResults, serialResult] : shardResults;
  const results: any[] = [];
  const failures: any[] = [];
  const notRun: { name: string; lane: string }[] = [];
  let passed = 0, failed = 0, aborted = 0, executed = 0, testTimeMs = 0;
  for (const lane of lanes) {
    const s = lane.summary;
    const ran = new Set<string>();
    if (s) {
      passed += s.passed; failed += s.failed; aborted += s.aborted; executed += s.executed;
      for (const r of s.results ?? []) {
        results.push({ ...r, lane: lane.label });
        ran.add(r.name);
        testTimeMs += r.duration_ms;
      }
      for (const f of s.failures ?? []) failures.push({ ...f, lane: lane.label });
    } else if (lane.rc !== 0) {
      failures.push({ name: `${lane.label} (no runner summary)`, error: lane.failureKind, lane: lane.label });
    }
    for (const name of lane.planned) if (!ran.has(name)) notRun.push({ name, lane: lane.label });
  }
  const rc = mergedExitCode(lanes.map((l) => l.rc));
  // A shard that exited non-zero always fails the merged gate, even when its runner never
  // reached a summary (build/launch failure, killed supervisor).
  const status = rc === 0 && failed === 0 && notRun.length === 0 ? "PASS" : "FAIL";
  const finalRc = status === "PASS" ? 0 : rc === 0 ? 1 : rc;
  const failureKind = status === "PASS"
    ? "none"
    : lanes.filter((l) => l.rc !== 0).map((l) => `${l.label}:${l.failureKind}`).join(",") || "test_not_run";
  const wallMs = Date.now() - t0;

  // Record durations of passing runs (failures are often timeouts and would skew the plan).
  if (status === "PASS" || results.length > 0) {
    const next: Record<string, number> = { ...recorded };
    for (const r of results) {
      if (r.status !== "pass") continue;
      const old = next[r.name];
      next[r.name] = old === undefined ? r.duration_ms : Math.round((old + r.duration_ms) / 2);
    }
    mkdirSync(dirname(durationsPath), { recursive: true });
    writeFileSync(`${durationsPath}.tmp`, JSON.stringify(next, Object.keys(next).sort(), 2));
    renameSync(`${durationsPath}.tmp`, durationsPath);
  }

  const summary = {
    mode: "parallel",
    jobs,
    seed,
    total_selected: selected.length,
    executed,
    passed,
    failed,
    aborted,
    not_run: notRun,
    wall_ms: wallMs,
    parallel_wall_ms: parallelMs,
    serial_wall_ms: serialResult?.wallMs ?? 0,
    test_time_ms: testTimeMs,
    exit_code: finalRc,
    failure_kind: failureKind,
    lanes: lanes.map((l) => ({
      label: l.label, rc: l.rc, failure_kind: l.failureKind, wall_ms: l.wallMs,
      session_dir: l.sessionDir, planned: l.planned.length,
      passed: l.summary?.passed ?? null, failed: l.summary?.failed ?? null, aborted: l.summary?.aborted ?? null,
    })),
    failures,
    results,
  };
  writeFileSync(join(outRoot, "summary.json"), JSON.stringify(summary, null, 2));

  // The manifest contract names gate.log as the primary log: concatenate the lanes' gate logs.
  const gateLog = lanes.map((l) => {
    const p = join(outRoot, l.label, "evidence", "gate.log");
    return `==== ${l.label} ====\n${existsSync(p) ? readFileSync(p, "utf8") : "(missing)\n"}`;
  }).join("\n");
  writeFileSync(join(outRoot, "gate.log"), gateLog);

  const manifest = spawnSync("bash", [
    "scripts/write_evidence_manifest.sh", manifestPath, "storybook-e2e", status, String(finalRc),
    "bash scripts/run_storybook_e2e_parallel.sh", outRoot, failureKind,
  ], {
    cwd: repo,
    env: { ...process.env, ZENIT_EVIDENCE_DURATION_MS: String(wallMs), ZENIT_TEST_SEED: seed === null ? "" : String(seed) },
    stdio: ["ignore", "ignore", "inherit"],
  });
  if (manifest.status !== 0) console.error("warning: failed to write merged evidence manifest");
  console.log(`\n  Results: ${passed} passed, ${failed} failed, ${aborted} aborted, ${notRun.length} not run` +
    ` — wall ${(wallMs / 1000).toFixed(1)}s (parallel ${(parallelMs / 1000).toFixed(1)}s` +
    `${serialResult ? ` + serial ${(serialResult.wallMs / 1000).toFixed(1)}s` : ""}), test time ${(testTimeMs / 1000).toFixed(1)}s`);
  if (failures.length > 0) {
    console.log("\n  Failures:");
    for (const f of failures) console.log(`    - [${f.lane}] ${f.name}: ${f.error}`);
  }
  if (notRun.length > 0) console.log(`\n  Not run: ${notRun.map((n) => `[${n.lane}] ${n.name}`).join("\n           ")}`);
  console.log(`\n  Summary: ${join(outRoot, "summary.json")}\n  Manifest: ${manifestPath}\n`);
  process.exit(finalRc);
}

if (import.meta.main) {
  main().catch((err) => {
    console.error(`parallel e2e supervisor failed: ${err?.stack ?? err}`);
    process.exit(1);
  });
}
