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

/** True when the suite drives an app on the Windows worker: through the host
 * HTTP queue, or run on the worker itself (windows_vm_http.py --suite-on-worker). */
export function runsOnWindowsWorker(): boolean {
  return Boolean(process.env.ZENIT_E2E_HTTP_JOB_ID) || process.platform === "win32";
}

export function getRpcDir(): string {
  return process.env.ZENIT_E2E_FILE_RPC_DIR ?? "/tmp/zenit_e2e_rpc_19816";
}

/**
 * Timeout diagnostics: read owner.json written by server (single-owner lock marker),
 * distinguish "silent timeout" into three attributable states. Old app skips owner.json,
 * degrade to "unclaimed" hint, protocol compatible.
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
  scale_x?: number;
  scale_y?: number;
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

// ── Core RPC ──

// The Windows worker answers a refused native-input action with ok:false; both
// transports surface it as an error.
function checkNativeInput(method: string, path: string, result: any): any {
  // Native input and desktop capture refusals arrive as {ok:false,error} over file RPC
  // (the HTTP queue answers 403 instead); surface both the same way.
  if ((path === "/windows/native-input" || path === "/windows/native-desktop") && result?.ok === false) {
    throw new Error(`Windows native input ${method} ${path}: ${result.error ?? "request refused"}`);
  }
  return result;
}

export async function request(
  method: string,
  path: string,
  body?: object,
): Promise<any> {
  const httpJob = process.env.ZENIT_E2E_HTTP_JOB_ID;
  if (httpJob) {
    const base = process.env.ZENIT_E2E_HTTP_BASE ?? "http://127.0.0.1:19817";
    const token = process.env.ZENIT_E2E_HTTP_TOKEN;
    if (!token) throw new Error("ZENIT_E2E_HTTP_TOKEN is required for Windows HTTP RPC");
    const response = await fetch(`${base}/rpc/${httpJob}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ method, path, body }),
      signal: AbortSignal.timeout(getE2eTimeoutMs(35000)),
    });
    const raw = await response.text();
    let result: any;
    try {
      result = JSON.parse(raw);
    } catch {
      throw new Error(`Windows HTTP RPC ${method} ${path}: HTTP ${response.status}, ${raw.slice(0, 160)}`);
    }
    if (!response.ok) throw new Error(`Windows HTTP RPC ${method} ${path}: ${JSON.stringify(result)}`);
    return checkNativeInput(method, path, result);
  }
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
      return checkNativeInput(method, path, value);
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
  renderer_backend?: "d3d12" | "d3d11" | "metal" | "null_backend" | "opengl" | "vulkan" | "legacy" | null;
  window_scale?: number | null;
  retained_hits: number;
  retained_misses: number;
  retained_partial_repaints: number;
  path_draw_calls: number;
  frame_count: number;
  backdrop_luminance_milli: number;
  /** Paint invariant: cumulative duplicate solid-rect count (same node, frame, identical fill emitted twice). Must be 0 */
  /** Hovered path's nearest test_id and stationary-pointer hover re-resolution counters. */
  hover: {
    test_id: string | null;
    reconcile_hit_tests: number;
    reconcile_changes: number;
    /** Platform presence: false after `pointer_left` until the next pointer event. */
    pointer_over_content: boolean;
    /** Stationary re-resolution may run: presence, inside the content, no OS drag session. */
    pointer_live: boolean;
  } | null;
  paint_duplicate_fills: number;
  /** Most recent double-emit node id (debug; 0 = never) */
  paint_duplicate_node: number;

  // ── Per-frame timing (microseconds) ──
  // High noise (drawable acquire / dispatch jitter / PSO compile), **log only, don't assert**.
  /** Last frame real GPU time (MTLCommandBuffer GPUEndTime-GPUStartTime) */
  gpu_execute_us: number;
  cpu_frame_us: number;
  layout_us: number;
  render_gen_us: number;
  gpu_encode_us: number;
  wait_for_frame_us?: number | null;
  acquire_texture_us?: number | null;
  encode_us?: number | null;
  flush_us?: number | null;
  total_frame_us: number;
  render_passes: number;
  blit_passes: number;
  compute_passes: number;

  // ── Cross-frame P95 (microseconds), perf gate assertion anti-noise statistic ──
  gpu_p95_us: number;
  cpu_p95_us: number;
  total_p95_us: number;
  /** P95 valid sample count; must confirm before assert, else judging empty loop (0 ever = false positive) */
  timing_samples: number;
  cpu_timing_samples?: number;
  gpu_timing_disjoint_samples?: number;
  gpu_timing_failed_samples?: number;
  gpu_timing_pending_queries?: number;
  gpu_timing_query_supported?: boolean | null;
}

export async function stats(): Promise<FrameStats> {
  return request("POST", "/stats", {});
}

/**
 * Clear cross-frame timing sample ring. Perf gate switches heavy scene, waits settle, calls this;
 * subsequent P95 counts only that scene (unmixes prior story samples).
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

/** count > 1 injects consecutive clicks inside the app in one request, so a
 *  double-click never depends on the driver's round-trip time. */
export async function clickAt(x: number, y: number, count = 1): Promise<ClickResult> {
  return request("POST", "/click", count === 1 ? { x, y } : { x, y, count });
}

/** Matches ui.events.ScrollPhase. Omit = mouse wheel. */
export type ScrollPhase = "none" | "may_begin" | "began" | "changed" | "ended" | "cancelled";

export interface ScrollMods {
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  cmd?: boolean;
  /** Trackpad gesture phase; omit -> dispatch as mouse wheel (each event to hit target). */
  phase?: ScrollPhase;
  /** Inertia phase after release */
  momentum?: "began" | "changed" | "ended";
}

/** Single scroll event. Default mouse wheel; trackpad gesture use trackpadScroll send full sequence. */
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
 * One complete trackpad gesture: began, changed per delta, ended (matches real device
 * event sequence). stepDelayMs controls event spacing.
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

/**
 * Resize the window's logical size (points). Resizing triggers a surface reconfigure, so this is the
 * regression anchor for the readback capability.
 */
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

/** The platform's `pointer_left` (the pointer left the window or another window covers it). */
export async function pointerLeave(): Promise<{ ok: boolean }> {
  return request("POST", "/pointer_leave", {});
}

/** The platform's window activation appearance (test-mode apps otherwise stay active). */
export async function setWindowActive(active: boolean): Promise<{ ok: boolean }> {
  return request("POST", "/window_active", { active });
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

export interface TrackSample { t: number; x: number; y: number; w: number; h: number; found: boolean }

/** Begin per-frame tracking: app records screen rect of this node each frame (animation assert, unrelated to RPC latency) */
export async function trackStart(testId: string): Promise<void> {
  await request("POST", "/track_start", { test_id: testId });
}

/** end per-frame tracking, get all samples (first sample is position when tracking started). error if samples hit app-side limit, later frames not recorded */
export async function trackStop(): Promise<TrackSample[]> {
  const r = (await request("POST", "/track_stop", {})) as { truncated: boolean; samples: TrackSample[] };
  if (r.truncated) throw new Error(`track_stop: sample limit reached after ${r.samples.length} frames; later frames were not recorded`);
  return r.samples;
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
  line_height?: number;
  padding_h?: number;
  padding_v?: number;
  cursor_rect?: { x: number; y: number; w: number; h: number } | null;
  selection_rects?: Array<{ x: number; y: number; w: number; h: number }>;
  ime_preedit_len: number;
  ime_phase: string;
  input_type: string;
  scroll_x: number;
  scroll_y?: number;
}

export async function inputState(testId: string): Promise<InputState> {
  return request("POST", "/input_state", { test_id: testId });
}

export async function windows(): Promise<{ windows: Array<{ window_id: string; native_id: string; bound: boolean; closing: boolean }> }> {
  return request("GET", "/windows");
}

export async function screenshot(path: string, window_id?: string): Promise<{ ok: boolean; path?: string }> {
  return request("POST", "/screenshot", { path, ...(window_id === undefined ? {} : { window_id }) });
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

// ── Host-custom routes (test-mode: app registers handler) ──

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
 * Request app enter test view / initial state. /scenario/setup is host custom route:
 * http_server.zig passes unmatched paths to host-registered handler. Contract:
 * idempotent, called per case, errors return {ok:false,error} explicitly; large data
 * uses state_key reference, not body (app route body limit 512B).
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
  // Warning: default must call getE2eTimeoutMs: else CI sets ZENIT_E2E_TIMEOUT_MS to 45s
  // only applies per-RPC, call sites that pass no explicit budget still wait a fixed 5s. Under load 'condition true at 6-40s'
  // lands in gap, error written 'waitFor timeout' blames feature not budget. Structural reason
  // e2e flaky under load.
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

/** Native UI-thread click and real-time submitted-frame capture; the HTTP hop
 * returns an already selected frame, never determines its sampling instant. */
export async function captureFrameAt(testId: string, clickTestId: string, afterMs: number, path: string): Promise<{ok:boolean; path:string; sample_ms:number; requested_ms:number; frame_index:number; x:number; effective_opacity:number}> {
  return request("POST", "/frames/capture", {test_id:testId, click_test_id:clickTestId, after_ms:afterMs, path});
}

/** Windows UI geometry sampled after each successful frame submission, without RPC polling.
 * Optional clickTestId dispatches a hit-tested background click on the same UI turn
 * after arming observation. Unsupported backends perform neither action nor observation.
 */
export async function startFrameObservation(testId: string, action?: "escape_on_enter", clickTestId?: string): Promise<{ supported: boolean }> {
  return request("POST", "/frames/start", { test_id: testId, action, click_test_id: clickTestId });
}
export async function readFrameObservation(): Promise<{ action_frame_index: number | null; overflow: boolean; missing: number; frames: Array<ScreenPos & { ms: number; opacity?: number; effective_opacity?: number }> }> {
  return request("POST", "/frames/read");
}
