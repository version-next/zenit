/**
 * e2e/controller.ts, scenario dashboard 的 localhost 后端
 *
 * 前端是 SolidJS + @zax/ui（tools/scenario-dashboard/，build 后 dist/）。
 * 同一套执行逻辑：触发跑 = spawn `scenario_runner.ts`（不另造执行逻辑）。
 *
 * 用法:
 *   bun e2e/controller.ts            # 默认 http://127.0.0.1:3900
 *
 * API:
 *   GET  /                            dashboard（tools/scenario-dashboard/dist）
 *   GET  /api/reports                列 report（含状态汇总）
 *   GET  /api/reports/:scenario/:run 单报告详情（产物路径重写为相对 base）
 *   GET  /api/scenarios              列 scenario
 *   POST /api/runs                   {scenario} -> 触发跑
 *   GET  /api/runs/:id               运行状态 + 日志尾
 *   GET  /reports/*                  静态服务 report 产物（html/json/png/mp4）
 */

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const PORT = Number(process.env.ZENIT_DASH_PORT ?? 3900);
const REPORTS_DIR = process.env.ZENIT_REPORTS_DIR ?? "reports";
const SCENARIOS_DIR = process.env.ZENIT_SCENARIOS_DIR ?? "e2e/scenarios";
const DASH_DIST = process.env.ZENIT_DASH_DIST ?? "tools/scenario-dashboard/dist";
const REPORTS_ABS = resolve(REPORTS_DIR);
const DASH_DIST_ABS = resolve(DASH_DIST);

interface RunInfo {
  id: string;
  scenario: string;
  status: "running" | "finished";
  exitCode?: number;
  startedAt: number;
  log: string;
}

const runs = new Map<string, RunInfo>();

function statusCounts(cases: Array<{ status?: string }>): Record<string, number> {
  const c = { pass: 0, fail: 0, needs_review: 0, error: 0 } as Record<string, number>;
  for (const x of cases) if (x.status) c[x.status] = (c[x.status] ?? 0) + 1;
  return c;
}

function listReports() {
  const out: Array<Record<string, unknown>> = [];
  if (!existsSync(REPORTS_DIR)) return out;
  for (const scenario of readdirSync(REPORTS_DIR)) {
    const sDir = join(REPORTS_DIR, scenario);
    if (!statSync(sDir).isDirectory()) continue;
    for (const run of readdirSync(sDir)) {
      const rp = join(sDir, run, "report.json");
      if (!existsSync(rp)) continue;
      try {
        const report = JSON.parse(readFileSync(rp, "utf8"));
        out.push({
          scenario, run,
          timestamp: report.timestamp,
          cases: report.cases?.length,
          ...statusCounts(report.cases ?? []),
          reportPath: `reports/${scenario}/${run}/report.html`,
        });
      } catch { /* 忽略损坏的 report */ }
    }
  }
  return out.sort((a, b) => String(b.timestamp ?? "").localeCompare(String(a.timestamp ?? "")));
}

function listScenarios(): string[] {
  if (!existsSync(SCENARIOS_DIR)) return [];
  return readdirSync(SCENARIOS_DIR).filter((f) => f.endsWith(".json") || f.endsWith(".yaml") || f.endsWith(".yml")).sort();
}

function triggerRun(scenario: string): string {
  const id = randomUUID().slice(0, 8);
  const info: RunInfo = { id, scenario, status: "running", startedAt: Date.now(), log: "" };
  runs.set(id, info);
  const child = spawn("bun", ["e2e/scenario_runner.ts", join(SCENARIOS_DIR, scenario)], { stdio: ["ignore", "pipe", "pipe"] });
  let log = "";
  const onData = (d: Buffer) => { log += d.toString(); info.log = log.slice(-6000); };
  child.stdout.on("data", onData);
  child.stderr.on("data", onData);
  child.on("exit", (code) => { info.status = "finished"; info.exitCode = code ?? undefined; });
  return id;
}

function getReport(scenario: string, run: string): Response {
  const rp = join(REPORTS_DIR, scenario, run, "report.json");
  if (!existsSync(rp)) return json({ error: "not found" }, 404);
  const report = JSON.parse(readFileSync(rp, "utf8"));
  const runAbs = resolve(REPORTS_DIR, scenario, run);
  const base = `/reports/${scenario}/${run}/`;
  report.base = base;
  for (const c of report.cases ?? []) {
    for (const a of c.artifacts ?? []) {
      if (a.path) a.path = relative(runAbs, a.path).replaceAll("\\", "/");
    }
  }
  return json(report);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html", ".json": "application/json", ".png": "image/png",
  ".mp4": "video/mp4", ".js": "text/javascript", ".css": "text/css",
  ".svg": "image/svg+xml", ".ico": "image/x-icon",
};

function serveFile(abs: string): Response {
  if (!existsSync(abs) || !statSync(abs).isFile()) return json({ error: "not found" }, 404);
  const ext = abs.slice(abs.lastIndexOf("."));
  const contentType = CONTENT_TYPES[ext] ?? "application/octet-stream";
  return new Response(readFileSync(abs), { headers: { "content-type": contentType } });
}

function serveReport(rel: string): Response {
  const abs = resolve(REPORTS_ABS, rel);
  if (!abs.startsWith(REPORTS_ABS + sep)) return json({ error: "forbidden" }, 403);
  return serveFile(abs);
}

function serveDist(rel: string): Response {
  const abs = resolve(DASH_DIST_ABS, rel);
  if (!abs.startsWith(DASH_DIST_ABS + sep)) return json({ error: "forbidden" }, 403);
  return serveFile(abs);
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;

    if (p === "/") {
      const index = join(DASH_DIST_ABS, "index.html");
      if (!existsSync(index)) {
        return new Response("dashboard 未构建：cd tools/scenario-dashboard && bun run build", {
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }
      return new Response(readFileSync(index), { headers: { "content-type": "text/html; charset=utf-8" } });
    }

    // 单报告详情（产物路径重写为相对 base）
    if (p.startsWith("/api/reports/")) {
      const rest = p.slice("/api/reports/".length).split("/");
      if (rest.length === 2 && rest[0] && rest[1]) return getReport(rest[0], rest[1]);
    }
    if (p === "/api/reports") return json(listReports());
    if (p === "/api/scenarios") return json(listScenarios());
    if (p === "/api/runs" && req.method === "POST") {
      const body = (await req.json().catch(() => ({}))) as { scenario?: string };
      if (!body.scenario) return json({ error: "scenario required" }, 400);
      return json({ runId: triggerRun(body.scenario) });
    }
    if (p.startsWith("/api/runs/")) {
      const id = p.slice("/api/runs/".length);
      const run = runs.get(id);
      return run ? json(run) : json({ error: "not found" }, 404);
    }
    if (p.startsWith("/reports/")) return serveReport(p.slice("/reports/".length));
    // dashboard 静态资源（dist/assets/* 等）
    if (p.startsWith("/assets/")) return serveDist(p.slice(1));

    return json({ error: "not found" }, 404);
  },
});

console.log(`scenario dashboard: http://127.0.0.1:${PORT}`);
console.log(`  reports dir   : ${REPORTS_ABS}`);
console.log(`  scenarios dir : ${SCENARIOS_DIR}`);
console.log(`  dashboard dist: ${DASH_DIST_ABS}`);
