#!/usr/bin/env bun
/**
 * scenario_runner.ts — zenit UI 自动化 runner（最小可靠闭环）
 *
 * 读 scenario（JSON 或 YAML）→ zig build → 起 app（精确 executable + 唯一 RPC dir）
 * → 逐 case：setup → 执行 timeline（wait_for/click/hover/screenshot/assert…）
 * → 抓帧 → design/golden 比对 → 落 report（JSON + 静态 HTML）。
 *
 * 对应 docs/internal/UI_AUTOMATION_PLAN.md §4（v2 schema）。
 *
 * 用法:
 *   bun e2e/scenario_runner.ts <scenario.json|scenario.yaml> [--out reports/] [--skip-build]
 *
 * 最小闭环暂支持的 timeline 操作（其余在「交互 DSL」阶段补）：
 *   wait / wait_for / screenshot / click / hover / assert
 * expect 支持: design（比对 reference PNG）、golden（比对 baseline PNG）、needs_review。
 */

import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, resolve, dirname, basename, relative } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import * as client from "./client";
import { compare as designCompare } from "./design_diff";
import { compareGoldenFiles } from "./golden_compare";
import { decodePng } from "./png";
import { startMockServer, type MockServer, type MockDef, type MockResponse } from "./mock";
import { exportNodes } from "./pencil_export";

// ── 类型（宽松，bun 直跑不做 strict 类型检查）──

interface Target {
  build: { step: string; args?: string[] };
  launch: { executable: string; args?: string[]; env?: Record<string, string> };
  viewport?: { expected_logical?: { width: number; height: number }; expected_scale?: number };
}

interface Setup {
  view?: string;
  state_key?: string;
}

interface PointerTarget {
  test_id: string;
  anchor?: { x: number; y: number };
  offset?: { x: number; y: number };
}

interface Scenario {
  version: number;
  meta: { id: string; title?: string; tags?: string[] };
  target: Target;
  mocks?: MockDef[];
  cases: CaseDef[];
}

interface CaseDef {
  name: string;
  setup?: Setup;
  mocks?: Record<string, MockResponse>;
  timeline: TimelineOp[];
  expect: ExpectDef[];
}

// timeline 每个条目是「单键对象」，如 { click: { target: ... } }
type TimelineOp = Record<string, any>;

type ExpectDef =
  | { kind: "design"; reference?: string; pen?: { file: string; node_id: string; scale?: number }; max_changed_ratio?: number; max_rmse?: number }
  | { kind: "golden"; baseline: string; pixel_delta_threshold?: number; max_changed_ratio?: number; max_rmse?: number }
  | { kind: "needs_review" };

interface Artifact {
  id: string;
  kind: "screenshot" | "recording";
  path: string;
}

interface CaseResult {
  name: string;
  status: "pass" | "fail" | "needs_review" | "error";
  duration_ms: number;
  error?: string;
  artifacts: Artifact[];
  expectations: Record<string, any>[];
}

interface Report {
  schema_version: 1;
  scenario_id: string;
  run_id: string;
  timestamp: string;
  commit?: string;
  dirty?: boolean;
  build_args: string[];
  executable_hash?: string;
  scenario_hash?: string;
  environment: Record<string, unknown>;
  cases: CaseResult[];
}

// ── load & validate ──

function loadScenario(path: string): Scenario {
  if (!existsSync(path)) throw new Error(`scenario not found: ${path}`);
  const raw = readFileSync(path, "utf8");
  let obj: unknown;
  if (path.endsWith(".yaml") || path.endsWith(".yml")) {
    obj = yamlToJson(raw, path);
  } else {
    obj = JSON.parse(raw);
  }
  return validateScenario(obj as Scenario, path);
}

/** macOS 自带 ruby，用它做可靠的 YAML→JSON（dev tooling 无外部依赖）。 */
function yamlToJson(yaml: string, path: string): unknown {
  const proc = spawnSync("ruby", ["-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", path], {
    encoding: "utf8",
  });
  if (proc.error || proc.status !== 0) {
    throw new Error(`YAML 转换失败（需要系统 ruby）: ${proc.stderr || proc.error}`);
  }
  return JSON.parse(proc.stdout);
}

function validateScenario(s: Scenario, path: string): Scenario {
  if (!s || typeof s !== "object") throw new Error(`scenario 不是对象: ${path}`);
  if (s.version !== 2) throw new Error(`仅支持 version 2，got ${s.version}`);
  if (!s.meta?.id) throw new Error("meta.id 必填");
  if (!s.target?.build?.step) throw new Error("target.build.step 必填");
  if (!s.target?.launch?.executable) throw new Error("target.launch.executable 必填");
  if (!Array.isArray(s.cases) || s.cases.length === 0) throw new Error("cases 非空数组必填");
  for (const c of s.cases) {
    if (!c.name) throw new Error("每个 case 需 name");
    if (!Array.isArray(c.timeline)) throw new Error(`case "${c.name}" timeline 需数组`);
    if (!Array.isArray(c.expect) || c.expect.length === 0) throw new Error(`case "${c.name}" expect 非空数组必填`);
  }
  return s;
}

// ── build & launch ──

function buildTarget(target: Target): void {
  const args = ["build", ...(target.build.args ?? []), target.build.step];
  console.log(`==> zig ${args.join(" ")}`);
  const proc = spawnSync("zig", args, { stdio: "inherit" });
  if (proc.error || proc.status !== 0) {
    throw new Error(`build failed (zig ${args.join(" ")}): rc=${proc.status}`);
  }
}

function launchApp(target: Target, rpcDir: string, logPath: string, extraEnv?: Record<string, string>) {
  const exe = target.launch.executable;
  if (!existsSync(exe) || !isExecutable(exe)) throw new Error(`可执行不存在或不可执行: ${exe}`);
  const env = {
    ...process.env,
    ZENIT_E2E_FILE_RPC_DIR: rpcDir,
    ...(target.launch.env ?? {}),
    ...(extraEnv ?? {}),
  } as Record<string, string>;
  const logFd = require("node:fs").openSync(logPath, "a");
  const proc = spawn(exe, target.launch.args ?? [], { env, stdio: ["ignore", logFd, logFd] });
  return {
    proc,
    kill() {
      try { proc.kill("SIGTERM"); } catch {}
    },
  };
}

function isExecutable(p: string): boolean {
  try {
    require("node:fs").accessSync(p, require("node:fs").constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// ── timeline 执行 ──

async function resolvePointer(target: PointerTarget): Promise<{ x: number; y: number }> {
  const pos = await client.screenPos(target.test_id);
  const ax = target.anchor?.x ?? 0.5;
  const ay = target.anchor?.y ?? 0.5;
  const ox = target.offset?.x ?? 0;
  const oy = target.offset?.y ?? 0;
  return { x: pos.x + pos.w * ax + ox, y: pos.y + pos.h * ay + oy };
}

async function waitForNode(pred: { test_id: string; visible?: boolean; text_contains?: string }, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const nodes = await client.query(pred.test_id);
      const node = nodes[0];
      if (node) {
        if (pred.visible === true && node.visible === false) { /* keep waiting */ }
        else if (pred.text_contains && !(node.text ?? "").includes(pred.text_contains)) { /* keep waiting */ }
        else return;
      }
    } catch {}
    await client.sleep(50);
  }
  throw new Error(`wait_for 超时: ${JSON.stringify(pred)}`);
}

async function waitForFocused(testId: string, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const f = await client.focused();
      if (f?.test_id === testId) return;
    } catch {}
    await client.sleep(50);
  }
  throw new Error(`wait_for focused 超时: ${testId}`);
}

async function waitForRequests(mockName: string, count: number, timeoutMs: number, mock?: MockServer): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if ((mock?.getAudit().counts[mockName] ?? 0) >= count) return;
    await client.sleep(50);
  }
  throw new Error(`wait_for requests 超时: ${mockName} >= ${count}`);
}

async function waitForConsole(level: string, count: number, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const snap = await client.consoleEvents(0, 200);
    if (snap.events.filter((e) => e.level === level).length >= count) return;
    await client.sleep(50);
  }
  throw new Error(`wait_for console 超时: level=${level} >= ${count}`);
}

async function waitForInputState(testId: string, pred: { buffer?: string; ime_phase?: string }, timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const st = await client.inputState(testId);
      if ((pred.buffer === undefined || st.buffer === pred.buffer) && (pred.ime_phase === undefined || st.ime_phase === pred.ime_phase)) return;
    } catch {}
    await client.sleep(50);
  }
  throw new Error(`wait_for input_state 超时: ${testId} ${JSON.stringify(pred)}`);
}

async function executeTimeline(
  ops: TimelineOp[],
  ctx: { outDir: string; epoch: number; mock?: MockServer },
): Promise<Artifact[]> {
  const artifacts: Artifact[] = [];
  for (const op of ops) {
    const keys = Object.keys(op);
    if (keys.length !== 1) throw new Error(`timeline 操作必须单键: ${JSON.stringify(op)}`);
    const kind = keys[0];
    const arg = op[kind];
    switch (kind) {
      case "wait": {
        await client.sleep(arg.ms ?? 0);
        break;
      }
      case "wait_for": {
        const p = arg as any;
        const timeout = p.timeout_ms ?? 5000;
        if (p.node) await waitForNode(p.node, timeout);
        else if (p.focused) await waitForFocused(p.focused.test_id, timeout);
        else if (p.requests) await waitForRequests(p.requests.mock, p.requests.count, timeout, ctx.mock);
        else if (p.console) await waitForConsole(p.console.level, p.console.count, timeout);
        else if (p.input_state) await waitForInputState(p.input_state.test_id, p.input_state, timeout);
        else throw new Error(`wait_for 缺少 node/focused/requests/console/input_state: ${JSON.stringify(p)}`);
        break;
      }
      case "click": {
        const pt = await resolvePointer(arg.target);
        await client.clickAt(pt.x, pt.y);
        break;
      }
      case "hover": {
        const pt = await resolvePointer(arg.target);
        await client.mouseMove(pt.x, pt.y);
        break;
      }
      case "press": {
        const pt = await resolvePointer(arg.target);
        await client.mouseDown(pt.x, pt.y);
        break;
      }
      case "release": {
        const pt = await resolvePointer(arg.target);
        await client.mouseUp(pt.x, pt.y);
        break;
      }
      case "pointer_drag": {
        const from = await resolvePointer(arg.from);
        const to = await resolvePointer(arg.to);
        await client.mouseDown(from.x, from.y);
        await client.mouseMove(to.x, to.y);
        await client.mouseUp(to.x, to.y);
        break;
      }
      case "key": {
        await client.key(arg.key, arg.modifiers);
        break;
      }
      case "text": {
        await client.type_(arg.text);
        break;
      }
      case "ime_preedit": {
        await client.imePreedit(arg.text, arg.cursor_utf8_offset ?? 0);
        break;
      }
      case "ime_commit": {
        await client.imeCommit(arg.text);
        break;
      }
      case "ime_cancel": {
        throw new Error("ime_cancel: harness 无 /ime_cancel 路由（P1 待补）");
      }
      case "scroll": {
        const pt = await resolvePointer(arg.target);
        await client.scrollAt(pt.x, pt.y, arg.dx ?? 0, arg.dy ?? 0, arg.modifiers);
        break;
      }
      case "file_drop": {
        const pt = await resolvePointer(arg.target);
        await client.dragAt(pt.x, pt.y, 3, (arg.paths ?? []).join("\n"));
        break;
      }
      case "recording_start": {
        const id = arg.id ?? "recording";
        const path = join(ctx.outDir, `${id}.mp4`);
        const r = await client.startWindowRecording(path, { fps: arg.fps ?? 60 });
        if (!r.ok) throw new Error(`recording_start 失败: ${JSON.stringify(r)}`);
        artifacts.push({ id, kind: "recording", path });
        break;
      }
      case "recording_stop": {
        const r = await client.stopWindowRecording();
        if (!r.ok) throw new Error(`recording_stop 失败: ${JSON.stringify(r)}`);
        break;
      }
      case "screenshot": {
        const id = arg.id ?? `shot-${artifacts.length}`;
        const path = join(ctx.outDir, `${id}.png`);
        const r = await client.screenshot(path);
        if (!r.ok) throw new Error(`screenshot 失败: ${JSON.stringify(r)}`);
        artifacts.push({ id, kind: "screenshot", path });
        break;
      }
      case "assert": {
        const p = arg as any;
        if (p.node) {
          const nodes = await client.query(p.node.test_id);
          const node = nodes[0];
          if (!node) throw new Error(`assert node 不存在: ${p.node.test_id}`);
          if (p.node.text_contains && !(node.text ?? "").includes(p.node.text_contains)) {
            throw new Error(`assert text_contains 失败: ${p.node.test_id} 不含 "${p.node.text_contains}"`);
          }
        } else if (p.focused) {
          const f = await client.focused();
          if (f?.test_id !== p.focused.test_id) throw new Error(`assert focused 失败: ${JSON.stringify(f)}`);
        } else if (p.requests) {
          const count = ctx.mock?.getAudit().counts[p.requests.mock] ?? 0;
          if (count !== p.requests.count) {
            throw new Error(`assert requests 失败: ${p.requests.mock} 期望 ${p.requests.count} 次，实际 ${count} 次`);
          }
        } else if (p.input_state) {
          const st = await client.inputState(p.input_state.test_id);
          if (p.input_state.buffer !== undefined && st.buffer !== p.input_state.buffer) {
            throw new Error(`assert input_state buffer 失败: 期望 "${p.input_state.buffer}" 实际 "${st.buffer}"`);
          }
          if (p.input_state.ime_phase !== undefined && st.ime_phase !== p.input_state.ime_phase) {
            throw new Error(`assert input_state ime_phase 失败: 期望 "${p.input_state.ime_phase}" 实际 "${st.ime_phase}"`);
          }
        } else if (p.console) {
          const snap = await client.consoleEvents(0, 200);
          const n = snap.events.filter((e) => e.level === p.console.level).length;
          if (n !== p.console.count) {
            throw new Error(`assert console 失败: level=${p.console.level} 期望 ${p.console.count} 条，实际 ${n} 条`);
          }
        } else {
          throw new Error(`assert 缺少 node/focused/requests/input_state/console: ${JSON.stringify(p)}`);
        }
        break;
      }
      default:
        throw new Error(`timeline 操作 "${kind}" 尚未在最小闭环实现`);
    }
  }
  return artifacts;
}

// ── expect 评估 ──

/** 从 .pen 取参考图（带缓存：.pen 未变则复用，避免每次 code 变更都重新导出）。 */
async function fetchPenReference(pen: { file: string; node_id: string; scale?: number }, scenarioId: string): Promise<string> {
  const cacheDir = join("designs-cache", scenarioId);
  mkdirSync(cacheDir, { recursive: true });
  const outPng = join(cacheDir, `${pen.node_id}.png`);
  if (existsSync(outPng) && existsSync(pen.file)) {
    const penMtime = statSync(pen.file).mtimeMs;
    const cacheMtime = statSync(outPng).mtimeMs;
    if (cacheMtime >= penMtime) return outPng;
  }
  console.log(`   [pen→png] export ${pen.node_id} (scale ${pen.scale ?? 2})`);
  const paths = await exportNodes({ filePath: pen.file, nodeIds: [pen.node_id], outputDir: cacheDir, scale: pen.scale ?? 2 });
  const p = paths.find((x) => x.endsWith(`${pen.node_id}.png`)) ?? paths[0];
  if (!p) throw new Error(`exportNodes 未返回 ${pen.node_id} 的 PNG`);
  return p;
}

async function evaluateExpect(exp: ExpectDef, artifacts: Artifact[], scenarioId: string): Promise<Record<string, any>> {
  if (exp.kind === "needs_review") {
    return { kind: "needs_review", ok: false, note: "需人工 review" };
  }
  // design/golden 都取最后一个 screenshot 产物做比对
  const shot = [...artifacts].reverse().find((a) => a.kind === "screenshot");
  if (!shot) throw new Error(`expect ${exp.kind} 需要截图产物，但 case 没截图`);
  if (exp.kind === "design") {
    const reference = exp.reference ?? await fetchPenReference(exp.pen!, scenarioId);
    const report = designCompare(decodePng(reference), decodePng(shot.path), {
      grid: 8, threshold: 8, top: 5,
    });
    const maxChanged = exp.max_changed_ratio ?? 0.05;
    const maxRmse = exp.max_rmse ?? 10;
    const ok = report.changedRatio <= maxChanged && report.rmse <= maxRmse;
    return { kind: "design", ok, reference, changed_ratio: report.changedRatio, rmse: report.rmse, score: report.score, hints: report.hints, heatmap: report.heatmap };
  }
  if (exp.kind === "golden") {
    const config: GoldenConfig = {
      pixel_delta_threshold: exp.pixel_delta_threshold ?? 0,
      max_changed_ratio: exp.max_changed_ratio ?? 0,
      max_rmse: exp.max_rmse ?? 0,
    };
    const r = compareGoldenFiles(exp.baseline, shot.path, config);
    return { kind: "golden", ok: r.ok, baseline: exp.baseline, changed_ratio: r.changed_ratio, rmse: r.rmse, error: r.error };
  }
  throw new Error(`未知 expect kind: ${(exp as any).kind}`);
}

// ── report ──

function writeReport(report: Report, outDir: string): { jsonPath: string; htmlPath: string } {
  mkdirSync(outDir, { recursive: true });
  const jsonPath = join(outDir, "report.json");
  writeFileSync(jsonPath, JSON.stringify(report, null, 2));
  const htmlPath = join(outDir, "report.html");
  writeFileSync(htmlPath, renderHtml(report, outDir));
  return { jsonPath, htmlPath };
}

function statusBadge(s: string): string {
  return s === "pass" ? "badge-success" : s === "fail" ? "badge-destructive" : s === "needs_review" ? "badge-warning" : "badge-destructive";
}
function statusLabel(s: string): string {
  return s === "pass" ? "通过" : s === "fail" ? "失败" : s === "needs_review" ? "待审" : "错误";
}

function renderExpect(e: Record<string, any>): string {
  if (e.kind === "needs_review") {
    return `<div class="expect"><div class="expect-head"><span class="badge badge-warning">needs_review</span><span class="muted">需人工 review（动画 / 玻璃等）</span></div></div>`;
  }
  const metrics = [
    e.score != null ? `<div class="metric"><span>score</span><b>${e.score.toFixed(1)}</b></div>` : "",
    e.changed_ratio != null ? `<div class="metric"><span>Δ像素</span><b>${(e.changed_ratio * 100).toFixed(2)}%</b></div>` : "",
    e.rmse != null ? `<div class="metric"><span>RMSE</span><b>${e.rmse.toFixed(2)}</b></div>` : "",
  ].join("");
  const ref = e.reference ? `<div class="muted ref">ref: ${escapeHtml(String(e.reference))}</div>`
    : e.baseline ? `<div class="muted ref">baseline: ${escapeHtml(String(e.baseline))}</div>` : "";
  const hints = Array.isArray(e.hints) && e.hints.length
    ? `<ul class="hints">${e.hints.map((h: string) => `<li>${escapeHtml(h)}</li>`).join("")}</ul>` : "";
  const heatmap = e.heatmap ? `<pre class="heatmap">${escapeHtml(e.heatmap)}</pre>` : "";
  return `<div class="expect ${e.ok ? "" : "expect-fail"}">
    <div class="expect-head">
      <span class="badge badge-secondary">${escapeHtml(e.kind)}</span>
      <span class="expect-ok">${e.ok ? "✓" : "✗"}</span>
      <div class="metrics">${metrics}</div>
    </div>
    ${ref}${hints}${heatmap}
  </div>`;
}

function renderHtml(report: Report, outDir: string): string {
  const counts: Record<string, number> = { pass: 0, fail: 0, needs_review: 0, error: 0 };
  for (const c of report.cases) counts[c.status] = (counts[c.status] ?? 0) + 1;

  const cards = report.cases.map((c) => {
    const shots = c.artifacts.filter((a) => a.kind === "screenshot").map((a) => {
      const rel = relative(outDir, a.path);
      return `<a class="shot" href="${rel}"><img src="${rel}" alt="${escapeHtml(a.id)}" /><span class="shot-label">${escapeHtml(a.id)}</span></a>`;
    }).join("");
    const recs = c.artifacts.filter((a) => a.kind === "recording").map((a) =>
      `<a class="rec" href="${relative(outDir, a.path)}">▶ ${escapeHtml(a.id)}</a>`).join("");
    const expects = c.expectations.map(renderExpect).join("");
    const err = c.error ? `<div class="error-box">${escapeHtml(c.error)}</div>` : "";
    return `<article class="card case">
      <header class="case-head">
        <h2>${escapeHtml(c.name)}</h2>
        <span class="badge ${statusBadge(c.status)}">${statusLabel(c.status)}</span>
      </header>
      <div class="case-body">
        ${shots ? `<div class="shots">${shots}</div>` : ""}
        ${recs ? `<div class="recs">${recs}</div>` : ""}
        ${expects ? `<div class="expects">${expects}</div>` : ""}
        ${err}
      </div>
    </article>`;
  }).join("");

  const summary = [
    counts.pass ? `<span class="badge badge-success">${counts.pass} 通过</span>` : "",
    counts.fail ? `<span class="badge badge-destructive">${counts.fail} 失败</span>` : "",
    counts.needs_review ? `<span class="badge badge-warning">${counts.needs_review} 待审</span>` : "",
    counts.error ? `<span class="badge badge-destructive">${counts.error} 错误</span>` : "",
  ].filter(Boolean).join(" ");

  const env = report.environment;
  const meta = [
    report.timestamp ? new Date(report.timestamp).toLocaleString() : "",
    report.run_id ? `run ${report.run_id}` : "",
    report.commit ? `commit ${report.commit}` : "",
    env?.os ? `os ${env.os}` : "",
    env?.arch ? env.arch : "",
    env?.scale ? `@${env.scale}x` : "",
  ].filter(Boolean).join(" · ");

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(report.scenario_id)} · 验收报告</title>
<style>
:root{
  --background:oklch(1 0 0);--foreground:oklch(0.145 0 0);
  --card:oklch(1 0 0);--card-foreground:oklch(0.145 0 0);
  --popover:oklch(1 0 0);--popover-foreground:oklch(0.145 0 0);
  --primary:oklch(0.205 0 0);--primary-foreground:oklch(0.985 0 0);
  --secondary:oklch(0.97 0 0);--secondary-foreground:oklch(0.205 0 0);
  --muted:oklch(0.97 0 0);--muted-foreground:oklch(0.556 0 0);
  --accent:oklch(0.97 0 0);--accent-foreground:oklch(0.205 0 0);
  --destructive:oklch(0.577 0.245 27.325);--destructive-foreground:oklch(0.985 0 0);
  --border:oklch(0.922 0 0);--input:oklch(0.922 0 0);--ring:oklch(0.708 0 0);
  --success:oklch(0.627 0.17 149.2);--warning:oklch(0.769 0.188 70.08);
  --radius:0.625rem;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--muted);color:var(--foreground);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;line-height:1.5;-webkit-font-smoothing:antialiased}
.wrap{max-width:960px;margin:0 auto;padding:2rem 1.5rem}
.card{border:1px solid var(--border);border-radius:var(--radius);background:var(--card);box-shadow:0 1px 2px 0 oklch(0 0 0 / 0.05)}
h1{font-size:1.25rem;font-weight:600;letter-spacing:-0.01em}
h2{font-size:0.9375rem;font-weight:600}
.muted{color:var(--muted-foreground);font-size:0.8125rem}
header.hero{padding:1.25rem 1.5rem;display:flex;flex-direction:column;gap:0.5rem}
.hero-meta{color:var(--muted-foreground);font-size:0.8125rem}
.badges{display:flex;flex-wrap:wrap;gap:0.5rem;margin-top:0.25rem}
.badge{display:inline-flex;align-items:center;border-radius:9999px;border:1px solid transparent;padding:0.125rem 0.625rem;font-size:0.75rem;font-weight:500;line-height:1.4}
.badge-success{background:color-mix(in oklab,var(--success) 15%,white);color:color-mix(in oklab,var(--success) 70%,black)}
.badge-destructive{background:color-mix(in oklab,var(--destructive) 12%,white);color:var(--destructive)}
.badge-warning{background:color-mix(in oklab,var(--warning) 18%,white);color:color-mix(in oklab,var(--warning) 75%,black)}
.badge-secondary{background:var(--secondary);color:var(--secondary-foreground);border-color:var(--border)}
.cases{display:flex;flex-direction:column;gap:1rem;margin-top:1rem}
.case{padding:1.25rem 1.5rem}
.case-head{display:flex;align-items:center;justify-content:space-between;gap:1rem;padding-bottom:0.875rem;border-bottom:1px solid var(--border)}
.case-body{display:flex;flex-direction:column;gap:1rem;padding-top:1rem}
.shots{display:flex;flex-wrap:wrap;gap:0.75rem}
.shot{display:flex;flex-direction:column;gap:0.375rem;text-decoration:none}
.shot img{max-width:240px;max-height:140px;border:1px solid var(--border);border-radius:calc(var(--radius) - 2px);object-fit:contain;background:white}
.shot-label{font-size:0.75rem;color:var(--muted-foreground)}
.recs{display:flex;flex-wrap:wrap;gap:0.5rem}
.rec{display:inline-flex;align-items:center;gap:0.375rem;padding:0.375rem 0.75rem;border:1px solid var(--border);border-radius:calc(var(--radius) - 2px);background:var(--secondary);color:var(--secondary-foreground);text-decoration:none;font-size:0.8125rem}
.rec:hover{background:var(--accent)}
.expects{display:flex;flex-direction:column;gap:0.75rem}
.expect{border:1px solid var(--border);border-radius:calc(var(--radius) - 2px);padding:0.875rem 1rem;display:flex;flex-direction:column;gap:0.625rem}
.expect-fail{border-color:color-mix(in oklab,var(--destructive) 40%,white)}
.expect-head{display:flex;align-items:center;gap:0.625rem}
.expect-ok{font-size:0.9375rem;font-weight:600;color:var(--success)}
.expect-fail .expect-ok{color:var(--destructive)}
.metrics{display:flex;gap:0.875rem;margin-left:auto}
.metric{display:flex;flex-direction:column;align-items:flex-end;line-height:1.2}
.metric span{font-size:0.6875rem;color:var(--muted-foreground);text-transform:uppercase;letter-spacing:0.03em}
.metric b{font-size:0.875rem;font-variant-numeric:tabular-nums;font-weight:600}
.ref{word-break:break-all}
.hints{list-style:none;display:flex;flex-direction:column;gap:0.375rem}
.hints li{font-size:0.8125rem;color:color-mix(in oklab,var(--warning) 70%,black);background:color-mix(in oklab,var(--warning) 10%,white);border-left:3px solid var(--warning);padding:0.375rem 0.625rem;border-radius:0 4px 4px 0}
.heatmap{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.75rem;line-height:1.25;background:var(--muted);border:1px solid var(--border);border-radius:calc(var(--radius) - 2px);padding:0.625rem;overflow-x:auto;color:var(--foreground)}
.error-box{font-size:0.8125rem;color:var(--destructive);background:color-mix(in oklab,var(--destructive) 8%,white);border:1px solid color-mix(in oklab,var(--destructive) 30%,white);border-radius:calc(var(--radius) - 2px);padding:0.625rem 0.75rem;font-family:ui-monospace,Menlo,monospace}
footer{text-align:center;color:var(--muted-foreground);font-size:0.75rem;padding:1.5rem 0 2rem}
</style>
</head>
<body>
<div class="wrap">
  <header class="card hero">
    <h1>${escapeHtml(report.scenario_id)}</h1>
    <div class="hero-meta">${escapeHtml(meta)}</div>
    <div class="badges">${summary}</div>
  </header>
  <section class="cases">${cards}</section>
  <footer>zenit scenario runner · report</footer>
</div>
</body>
</html>`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ── main ──

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const flags = new Set<string>();
  const positional: string[] = [];
  const valueFlags = new Set(["--out"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      flags.add(a);
      if (valueFlags.has(a)) i++; // 消费该 flag 的值
      continue;
    }
    positional.push(a);
  }
  if (positional.length !== 1) {
    console.error("usage: bun e2e/scenario_runner.ts <scenario.json|.yaml> [--out <dir>] [--skip-build]");
    process.exit(64);
  }
  const scenarioPath = resolve(positional[0]);
  const scenario = loadScenario(scenarioPath);

  const outRoot = flagValue(argv, "--out") ?? "reports";
  const runId = randomUUID().slice(0, 8);
  const timestamp = new Date().toISOString();
  const report: Report = {
    schema_version: 1,
    scenario_id: scenario.meta.id,
    run_id: runId,
    timestamp,
    build_args: ["build", ...(scenario.target.build.args ?? []), scenario.target.build.step],
    environment: {
      os: process.platform,
      arch: process.arch,
      scale: scenario.target.viewport?.expected_scale ?? null,
      expected_logical: scenario.target.viewport?.expected_logical ?? null,
    },
    cases: [],
  };
  try {
    report.commit = gitHash();
    report.dirty = gitDirty();
  } catch { /* 非 git 环境可忽略 */ }

  if (!flags.has("--skip-build")) {
    buildTarget(scenario.target);
  }

  // 内嵌 mock（同进程，不单独起）。app 经 ZENIT_API_BASE 指向它。
  const mock: MockServer | undefined = scenario.mocks && scenario.mocks.length > 0
    ? startMockServer(scenario.mocks, dirname(scenarioPath))
    : undefined;
  if (mock) console.log(`==> mock: ${mock.url}`);

  for (let i = 0; i < scenario.cases.length; i++) {
    const caseDef = scenario.cases[i];
    const caseSlug = slug(caseDef.name) || `case${i}`;
    // 绝对路径：harness 的 recording/screenshot 有些要求绝对路径（recording 严格校验）
    const caseOut = resolve(join(outRoot, scenario.meta.id, runId, `case-${i}-${caseSlug}`));
    mkdirSync(caseOut, { recursive: true });
    const rpcDir = join(tmpdir(), `zenit_scenario_${runId}_${i}`);
    mkdirSync(rpcDir, { recursive: true });
    const logPath = join(caseOut, "app.log");
    const app = launchApp(scenario.target, rpcDir, logPath, mock ? { ZENIT_API_BASE: mock.url } : undefined);

    // client 从 process.env 读 RPC dir —— 必须和 app 用同一个目录（文件 RPC，不是 HTTP）。
    process.env.ZENIT_E2E_FILE_RPC_DIR = rpcDir;

    const started = Date.now();
    const result: CaseResult = {
      name: caseDef.name,
      status: "error",
      duration_ms: 0,
      artifacts: [],
      expectations: [],
    };

    try {
      await client.waitForServerReady();

      // setup（app 未注册 /scenario/setup 时 404，容忍并继续）
      if (caseDef.setup) {
        const setup = caseDef.setup;
        try {
          const resp = await client.scenarioSetup({
            contract: 1,
            case_id: `${i}-${caseSlug}`,
            epoch: i,
            state_key: setup.state_key ?? setup.view ?? caseDef.name,
          });
          if (!resp.ok) throw new Error(`setup 失败: ${JSON.stringify(resp)}`);
        } catch (err: any) {
          if (/unknown route|404/.test(String(err?.message ?? err))) {
            console.log(`   [setup] app 未注册 /scenario/setup，跳过（${caseDef.name}）`);
          } else {
            throw err;
          }
        }
      }

      // 每 case 原子激活 mock 覆盖 + 清审计
      mock?.resetAudit();
      mock?.setCaseOverrides(caseDef.mocks ?? {});

      const ctx = { outDir: caseOut, epoch: i, mock };
      result.artifacts = await executeTimeline(caseDef.timeline, ctx);

      // 未匹配的 mock 请求 → 该 case 失败（漏 mock 的调用要显式暴露）
      const unmatched = mock?.getAudit().unmatched ?? [];
      if (unmatched.length > 0) {
        throw new Error(`存在未匹配的 mock 请求: ${JSON.stringify(unmatched)}`);
      }

      for (const exp of caseDef.expect) {
        result.expectations.push(await evaluateExpect(exp, result.artifacts, scenario.meta.id));
      }

      // 状态判定：任一自动 expect 失败 → fail；全是 needs_review → needs_review；否则 pass
      const auto = result.expectations.filter((e) => e.kind !== "needs_review");
      const anyFail = auto.some((e) => e.ok === false);
      if (anyFail) result.status = "fail";
      else if (auto.length === 0) result.status = "needs_review";
      else result.status = "pass";

      // design-pass → 存 golden-candidate（人工评审后经单独提交晋升为 approved baseline，不直接覆盖）
      for (let e = 0; e < result.expectations.length; e++) {
        const res = result.expectations[e];
        if (res.kind === "design" && res.ok === true) {
          const shot = [...result.artifacts].reverse().find((a) => a.kind === "screenshot");
          if (shot) {
            const candDir = join("golden-candidate", scenario.meta.id);
            mkdirSync(candDir, { recursive: true });
            const candPath = join(candDir, `${caseSlug}.png`);
            copyFileSync(shot.path, candPath);
            res.golden_candidate = candPath;
            console.log(`   [golden-candidate] ${candPath}`);
          }
        }
      }
    } catch (err: any) {
      result.status = "error";
      result.error = err?.message ?? String(err);
    } finally {
      app.kill();
      result.duration_ms = Date.now() - started;
      report.cases.push(result);
      const mark = result.status === "pass" ? "✓" : result.status === "needs_review" ? "👁" : result.status === "fail" ? "✗" : "⚠";
      console.log(`   [${mark} ${result.status}] ${caseDef.name} (${result.duration_ms}ms)${result.error ? ` — ${result.error}` : ""}`);
    }
  }

  mock?.stop();
  const { jsonPath, htmlPath } = writeReport(report, join(outRoot, scenario.meta.id, runId));
  const summary = report.cases.map((c) => `${c.status}:${c.name}`).join(", ");
  console.log(`==> report: ${jsonPath}`);
  console.log(`==> html  : ${htmlPath}`);
  console.log(`==> ${report.cases.length} cases → ${summary}`);
}

function flagValue(argv: string[], name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : undefined;
}

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function gitHash(): string | undefined {
  const p = spawnSync("git", ["rev-parse", "--short", "HEAD"], { encoding: "utf8" });
  return p.status === 0 ? p.stdout.trim() : undefined;
}

function gitDirty(): boolean {
  const p = spawnSync("git", ["status", "--porcelain"], { encoding: "utf8" });
  return p.status === 0 && p.stdout.trim().length > 0;
}

if (import.meta.main) main().catch((err) => {
  console.error("runner failed:", err?.message ?? err);
  process.exit(1);
});
