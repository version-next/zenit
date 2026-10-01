/**
 * Typed Zenit automation Harness client (file RPC).
 *
 * Downstream applications can install this file at the stable path
 * `zig-out/share/zenit/harness/client.ts` with
 * `zenit.installHarnessClient(b, zenit_dep)`. Build the Zenit dependency with
 * `.@"test-mode" = true`, then give the application and controller the same
 * `ZENIT_E2E_FILE_RPC_DIR`. Without the environment variable, both use
 * `/tmp/zenit_e2e_rpc_<e2e-port>` (19816 by default).
 */

import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

export function getRpcDir(): string {
  return process.env.ZENIT_E2E_FILE_RPC_DIR ?? "/tmp/zenit_e2e_rpc_19816";
}

/**
 * 诊断超时：读 server 写入的 owner.json（单主锁标记），把"沉默超时"分为
 * 三种可定责的状态。旧版 app 不写 owner.json，此时降级为 "unclaimed" 提示，
 * 不影响协议兼容。
 */
async function ownerDiagnostic(rpcDir: string): Promise<string> {
  let text: string;
  try {
    text = await readFile(join(rpcDir, "owner.json"), "utf8");
  } catch {
    return "owner.json missing: no server ever claimed this dir (app not started, wrong dir, or pre-owner-lock app build)";
  }
  let pid: number;
  try {
    pid = Number(JSON.parse(text)?.pid);
  } catch {
    return "owner.json malformed";
  }
  if (!Number.isFinite(pid) || pid <= 0) return "owner.json has no valid pid";
  try {
    process.kill(pid, 0);
    return `owner pid ${pid} is alive: server busy or wedged, not a transport fault`;
  } catch (err: any) {
    if (err?.code === "EPERM") return `owner pid ${pid} is alive (EPERM): server busy or wedged`;
    return `owner pid ${pid} is NOT running: app crashed or was killed mid-run`;
  }
}

/**
 * Shared timeout budget for RPC and higher-level readiness waits.
 *
 * `minimumMs` preserves a call site's deliberately longer local budget while
 * still allowing CI's `ZENIT_E2E_TIMEOUT_MS` to relax every dependent wait.
 */
export function getE2eTimeoutMs(minimumMs = 0): number {
  const raw = process.env.ZENIT_E2E_TIMEOUT_MS ?? "10000";
  const configured = Number(raw);
  if (!Number.isFinite(configured) || configured <= 0) {
    throw new Error(`invalid ZENIT_E2E_TIMEOUT_MS: ${JSON.stringify(raw)}`);
  }
  return Math.max(minimumMs, configured);
}

// ── Types ──

export interface QueryNode {
  id: number;
  tag: string;
  test_id?: string;
  component?: string;
  rect: { x: number; y: number; w: number; h: number };
  text?: string;
  focusable?: boolean;
  visible?: boolean;
  opacity?: number;
  rotate?: number;
  translate_x?: number;
  translate_y?: number;
  children?: QueryNode[];
}

export interface FocusedResult {
  id?: number;
  tag?: string;
  test_id?: string;
  component?: string;
  text?: string;
  focused?: null;
}

export interface ScreenPos {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface ClickResult {
  ok: boolean;
  clicked_x?: number;
  clicked_y?: number;
  error?: string;
}

export interface WindowRecordingState {
  ok: boolean;
  active: boolean;
  width: number;
  height: number;
  fps: number;
  duration_ms: number;
  file_size: number;
  frame_count: number;
  dropped_frames: number;
  codec: "h264";
  container: "mp4";
  path?: string;
  error?: string;
}

// ── 核心 RPC ──

export async function request(
  method: string,
  path: string,
  body?: object,
): Promise<any> {
  // Validate before publishing a request so a malformed environment value
  // cannot leave an orphaned req-*.json behind.
  const timeoutMs = getE2eTimeoutMs();
  const rpcDir = getRpcDir();
  await mkdir(rpcDir, { recursive: true });

  const id = randomUUID();
  const reqTmp = join(rpcDir, `req-${id}.tmp`);
  const reqPath = join(rpcDir, `req-${id}.json`);
  const resPath = join(rpcDir, `res-${id}.json`);
  const payload = JSON.stringify({
    method,
    path,
    body_json: body ? JSON.stringify(body) : "",
  });

  await writeFile(reqTmp, payload, "utf8");
  await rename(reqTmp, reqPath);

  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    let text: string;
    try {
      text = await readFile(resPath, "utf8");
    } catch (err: any) {
      if (err?.code && err.code !== "ENOENT") throw err;
      await sleep(20);
      continue;
    }

    await rm(reqPath, { force: true });
    await rm(resPath, { force: true });
    try {
      const value = JSON.parse(text);
      if (value === null || typeof value !== "object") {
        throw new Error(`response must be a JSON object or array, got ${typeof value}`);
      }
      return value;
    } catch (err: any) {
      // A present response is a completed protocol message. Never turn a
      // malformed/truncated message into a successful-looking `{raw: ...}`
      // value: health checks must fail closed and explain the transport fault.
      throw new Error(
        `malformed file-RPC response for ${method} ${path}: ${err?.message ?? err}; ` +
        `body=${JSON.stringify(text.slice(0, 160))}`,
      );
    }
  }

  await rm(reqPath, { force: true });
  const diag = await ownerDiagnostic(rpcDir);
  throw new Error(`request timeout: ${method} ${path} (rpc_dir=${rpcDir}; ${diag})`);
}

// ── API ──

export async function health(): Promise<{ status: "ok" }> {
  const result = await request("GET", "/health");
  if (result?.status !== "ok") {
    throw new Error(`invalid health response: ${JSON.stringify(result)}`);
  }
  return result;
}

export async function tree(): Promise<QueryNode> {
  return request("GET", "/tree");
}

export async function focused(): Promise<FocusedResult> {
  return request("GET", "/focused");
}

export async function query(testId: string): Promise<QueryNode[]> {
  return request("POST", "/query", { test_id: testId });
}

export interface FrameStats {
  retained_hits: number;
  retained_misses: number;
  retained_partial_repaints: number;
  path_draw_calls: number;
  frame_count: number;
  backdrop_luminance_milli: number;

  // ── 单帧计时（微秒）──
  // 噪声大（drawable 获取/调度抖动/PSO 编译），**只用于 log，不要断言**。
  /** 上一帧真 GPU 执行时间（MTLCommandBuffer GPUEndTime-GPUStartTime） */
  gpu_execute_us: number;
  cpu_frame_us: number;
  layout_us: number;
  render_gen_us: number;
  gpu_encode_us: number;
  total_frame_us: number;

  // ── 跨帧 P95（微秒），性能门禁断言用的抗噪统计量 ──
  gpu_p95_us: number;
  cpu_p95_us: number;
  total_p95_us: number;
  /** P95 的有效样本数；断言前必须确认它足够大，否则是在对空环下判断（恒 0 = 假绿） */
  timing_samples: number;
}

export async function stats(): Promise<FrameStats> {
  return request("POST", "/stats", {});
}

/**
 * 清空跨帧计时采样环。性能门禁切到重场景并等其 settle 后调用，
 * 使随后的 P95 只统计该场景自己的帧（不混入上一个 story 的样本）。
 */
export async function resetTiming(): Promise<{ ok: boolean }> {
  return request("POST", "/stats/reset", {});
}

export interface ConsoleEvent {
  seq: number;
  monotonic_us: number;
  thread_id: number;
  level: "debug" | "log" | "info" | "warn" | "error";
  kind: string;
  scope: string;
  group_depth: number;
  message: string;
  truncated: boolean;
  source?: { file: string; fn_name: string; line: number; column: number };
}

export interface ConsoleSnapshot {
  events: ConsoleEvent[];
  next_cursor: number;
  oldest_seq: number;
  newest_seq: number;
  gap: boolean;
  has_more: boolean;
  evicted_total: number;
  dropped_oom: number;
  dropped_oversize: number;
  clear_generation: number;
}

export async function consoleEvents(afterSeq = 0, limit = 100): Promise<ConsoleSnapshot> {
  return request("POST", "/console", { after_seq: String(afterSeq), limit });
}

export async function clearConsole(): Promise<{ ok: boolean }> {
  return request("POST", "/console/clear", {});
}

export async function waitForConsole(
  predicate: { text: string; level?: ConsoleEvent["level"] },
  timeoutMs = getE2eTimeoutMs(5_000),
  afterSeq = 0,
): Promise<ConsoleEvent> {
  const started = Date.now();
  let cursor = afterSeq;
  const recent: ConsoleEvent[] = [];
  while (Date.now() - started < timeoutMs) {
    const snapshot = await consoleEvents(cursor, 100);
    for (const event of snapshot.events) {
      recent.push(event);
      if (event.message.includes(predicate.text) && (!predicate.level || event.level === predicate.level)) return event;
    }
    cursor = snapshot.next_cursor;
    await sleep(25);
  }
  throw new Error(`console event timeout: ${JSON.stringify(predicate)}; recent=${JSON.stringify(recent.slice(-10))}`);
}

export async function clickAt(x: number, y: number): Promise<ClickResult> {
  return request("POST", "/click", { x, y });
}

/** 与 ui.events.ScrollPhase 一致。省略 = 鼠标滚轮。 */
export type ScrollPhase = "none" | "may_begin" | "began" | "changed" | "ended" | "cancelled";

export interface ScrollMods {
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  cmd?: boolean;
  /** 触控板手势阶段；省略时按鼠标滚轮派发（每个事件按命中目标）。 */
  phase?: ScrollPhase;
  /** 松手后的惯性阶段 */
  momentum?: "began" | "changed" | "ended";
}

/** 单个滚动事件。默认是鼠标滚轮；触控板手势请用 trackpadScroll 发完整序列。 */
export async function scrollAt(x: number, y: number, dx: number, dy: number, mods: ScrollMods = {}): Promise<{ ok: boolean }> {
  const body: Record<string, unknown> = { x, y, dx, dy };
  if (mods.shift) body.shift = true;
  if (mods.ctrl) body.ctrl = true;
  if (mods.alt) body.alt = true;
  if (mods.cmd) body.cmd = true;
  if (mods.phase) body.phase = mods.phase;
  if (mods.momentum) body.momentum = mods.momentum;
  return request("POST", "/scroll", body);
}

/**
 * 一次完整的触控板手势：began、每个增量一个 changed、最后 ended（与真实设备
 * 的事件序列一致）。stepDelayMs 控制事件间隔。
 */
export async function trackpadScroll(
  x: number,
  y: number,
  deltas: Array<[number, number]>,
  opts: { stepDelayMs?: number; mods?: Omit<ScrollMods, "phase" | "momentum"> } = {},
): Promise<void> {
  const delay = opts.stepDelayMs ?? 16;
  const mods = opts.mods ?? {};
  await scrollAt(x, y, 0, 0, { ...mods, phase: "began" });
  for (const [dx, dy] of deltas) {
    await scrollAt(x, y, dx, dy, { ...mods, phase: "changed" });
    if (delay > 0) await new Promise((r) => setTimeout(r, delay));
  }
  await scrollAt(x, y, 0, 0, { ...mods, phase: "ended" });
}

/** phase: 0=began 1=changed 2=ended 3=cancelled */
export async function magnifyAt(x: number, y: number, magnification: number, phase: number): Promise<{ ok: boolean }> {
  return request("POST", "/magnify", { x, y, magnification, phase });
}

/** kind: 0=entered 1=updated 2=exited 3=dropped */
export async function dragAt(x: number, y: number, kind: number, paths = ""): Promise<{ ok: boolean }> {
  return request("POST", "/drag", { x, y, kind, paths });
}

/** 调整窗口逻辑尺寸（点）。resize 会触发 surface 重配，readback 能力回归锚点。 */
export async function resizeWindow(width: number, height: number): Promise<{ ok: boolean }> {
  return request("POST", "/resize", { width, height });
}

export async function clickTestId(testId: string): Promise<ClickResult> {
  return request("POST", "/click", { test_id: testId });
}

export async function mouseDown(x: number, y: number): Promise<{ ok: boolean }> {
  return request("POST", "/mouse_down", { x, y });
}

export async function mouseMove(x: number, y: number): Promise<{ ok: boolean }> {
  return request("POST", "/mouse_move", { x, y });
}

export async function mouseUp(x: number, y: number): Promise<{ ok: boolean }> {
  return request("POST", "/mouse_up", { x, y });
}

export async function key(name: string, mods?: { shift?: boolean; ctrl?: boolean; alt?: boolean; cmd?: boolean }): Promise<{ ok: boolean }> {
  const body: any = { key: name };
  if (mods?.shift) body.shift = true;
  if (mods?.ctrl) body.ctrl = true;
  if (mods?.alt) body.alt = true;
  if (mods?.cmd) body.cmd = true;
  return request("POST", "/key_down", body);
}

export async function type_(text: string): Promise<{ ok: boolean }> {
  return request("POST", "/text_input", { text });
}

export async function imePreedit(text: string, cursorUtf8Offset: number = 0): Promise<{ ok: boolean }> {
  return request("POST", "/ime_preedit", { text, cursor_utf8_offset: cursorUtf8Offset });
}

export async function imeCommit(text: string): Promise<{ ok: boolean }> {
  return request("POST", "/ime_commit", { text });
}

export async function screenPos(testId: string): Promise<ScreenPos> {
  return request("POST", "/screen_pos", { test_id: testId });
}

export interface InputState {
  buffer_len: number;
  buffer: string;
  cursor_pos: number;
  /** UTF-8 byte offset; -1 means there is no active selection. */
  anchor?: number;
  cursor_affinity?: "upstream" | "downstream";
  /** Textarea-only visual geometry, populated after a render pass. */
  display_line_count?: number;
  cursor_rect?: { x: number; y: number; w: number; h: number } | null;
  selection_rects?: Array<{ x: number; y: number; w: number; h: number }>;
  ime_preedit_len: number;
  ime_phase: string;
  input_type: string;
  scroll_x: number;
}

export async function inputState(testId: string): Promise<InputState> {
  return request("POST", "/input_state", { test_id: testId });
}

export async function screenshot(path: string): Promise<{ ok: boolean; path?: string }> {
  return request("POST", "/screenshot", { path });
}

/**
 * Record only the bound Zenit application window at native Retina resolution.
 * The OS cursor is excluded; Harness's rendered virtual cursor is included.
 */
export async function startWindowRecording(
  path: string,
  options: { fps?: number } = {},
): Promise<WindowRecordingState> {
  return request("POST", "/recording/start", { path, fps: options.fps ?? 60 });
}

export async function windowRecordingStatus(): Promise<WindowRecordingState> {
  return request("POST", "/recording/status");
}

/** Stop capture and wait until the MP4 file has been finalized. */
export async function stopWindowRecording(): Promise<WindowRecordingState> {
  return request("POST", "/recording/stop");
}

// ── 宿主自定义路由（test-mode 下由 app 注册 handler）──

export interface ScenarioSetupRequest {
  contract: number;
  case_id: string;
  epoch: number;
  state_key: string;
}

export interface ScenarioSetupResponse {
  ok: boolean;
  contract: number;
  epoch: number;
  ready: boolean;
  state_hash?: string;
  error?: string;
}

/**
 * 请求 app 进入某个测试 view / 初始 state。`/scenario/setup` 是宿主自定义路由：
 * http_server.zig 会把未命中内置路由的路径原样转交宿主注册的 handler。
 * 约定：幂等、每 case 调用、错误用 `{ok:false,error}` 显式返回；大 data 用
 * `state_key` 引用，不塞 body（app route body 上限 512B）。
 */
export async function scenarioSetup(payload: ScenarioSetupRequest): Promise<ScenarioSetupResponse> {
  return request("POST", "/scenario/setup", payload);
}

// ── Utils ──

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function waitFor<T>(
  fn: () => Promise<T | null | undefined>,
  // ⚠ 默认值必须走 getE2eTimeoutMs：否则 CI 把 ZENIT_E2E_TIMEOUT_MS 放宽到
  // 45s 只对单次 RPC 生效，不传预算的调用点仍死等 5s。负载下「条件在第
  // 6~40s 满足」正好落进这个缺口，报错还会写成 "waitFor timeout"，
  // 把排查引向被测功能而不是超时预算。这是 e2e 在负载下 flaky 的结构性原因。
  timeoutMs = getE2eTimeoutMs(5000),
  pollMs = 50,
): Promise<T> {
  const started = Date.now();
  let lastError: unknown;
  while (Date.now() - started < timeoutMs) {
    try {
      const result = await fn();
      if (result != null && result !== false) return result;
    } catch (err) {
      lastError = err;
    }
    await sleep(pollMs);
  }
  const detail = lastError == null
    ? ""
    : `; last error: ${lastError instanceof Error ? lastError.message : String(lastError)}`;
  throw new Error(`waitFor timeout after ${timeoutMs}ms${detail}`);
}

export async function waitForServerReady(timeoutMs = getE2eTimeoutMs(10000)): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const r = await health();
      if (r.status === "ok") return;
    } catch {}
    await sleep(100);
  }
  throw new Error(`server not ready after ${timeoutMs}ms`);
}
