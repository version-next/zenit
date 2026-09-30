/**
 * e2e/watcher.ts — HMR 体验薄壳：监听 .zig 变更 → 重跑 scenario → 自动验收报告
 *
 * 这是「保存即自动验收」的最后一环，骑在 scenario_runner 之上，不另造执行逻辑。
 *
 * 用法:
 *   bun e2e/watcher.ts                          # 监听 src,examples，跑全部 scenario
 *   ZENIT_SCENARIO=smoke.design-probe.json \
 *   ZENIT_WATCH_DIRS=src,examples \
 *   ZENIT_DEBOUNCE_MS=800 bun e2e/watcher.ts
 */

import { watch, existsSync, readdirSync } from "node:fs";
import { spawn } from "node:child_process";
import { join } from "node:path";

const WATCH_DIRS = (process.env.ZENIT_WATCH_DIRS ?? "src,examples").split(",").map((s) => s.trim()).filter(Boolean);
const SCENARIO = process.env.ZENIT_SCENARIO; // 可选：只跑这一个
const DEBOUNCE_MS = Number(process.env.ZENIT_DEBOUNCE_MS ?? 800);
const SCENARIOS_DIR = process.env.ZENIT_SCENARIOS_DIR ?? "e2e/scenarios";

function listScenarios(): string[] {
  if (SCENARIO) return [SCENARIO];
  if (!existsSync(SCENARIOS_DIR)) return [];
  return readdirSync(SCENARIOS_DIR).filter((f) => f.endsWith(".json") || f.endsWith(".yaml") || f.endsWith(".yml")).sort();
}

let timer: ReturnType<typeof setTimeout> | undefined;
let running = false;
let pending = false;

function trigger(reason: string) {
  console.log(`  变更: ${reason}`);
  clearTimeout(timer);
  timer = setTimeout(() => {
    if (running) { pending = true; return; }
    runAll();
  }, DEBOUNCE_MS);
}

function runAll() {
  const scenarios = listScenarios();
  if (scenarios.length === 0) { console.log("==> 无 scenario 可跑"); return; }
  running = true;
  console.log(`\n==> 重跑 ${scenarios.length} 个 scenario…`);
  runNext(scenarios, 0);
}

function runNext(scenarios: string[], i: number) {
  if (i >= scenarios.length) {
    running = false;
    if (pending) { pending = false; runAll(); }
    else console.log("==> 全部完成\n");
    return;
  }
  const s = scenarios[i];
  const child = spawn("bun", ["e2e/scenario_runner.ts", join(SCENARIOS_DIR, s)], { stdio: "inherit" });
  child.on("exit", (code) => {
    console.log(`   [${code === 0 ? "✓" : "✗"}] ${s} (exit ${code})`);
    runNext(scenarios, i + 1);
  });
}

console.log(`watcher: 监听 ${WATCH_DIRS.join(", ")} 的 .zig 变更，debounce ${DEBOUNCE_MS}ms，scenario: ${SCENARIO ?? "全部"}`);
for (const dir of WATCH_DIRS) {
  if (!existsSync(dir)) { console.log(`  ⚠ 跳过不存在的目录: ${dir}`); continue; }
  watch(dir, { recursive: true }, (_event, filename) => {
    if (filename && filename.endsWith(".zig")) trigger(filename);
  });
  console.log(`  监听 ${dir}`);
}
console.log("  等待变更…（Ctrl-C 退出）");
