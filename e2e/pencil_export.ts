/**
 * e2e/pencil_export.ts, .pen -> PNG 导出 adapter（design_source）
 *
 * 通过 Pencil MCP（stdio JSON-RPC 2.0）调 `export_nodes`，把 .pen 的某个节点导出成
 * PNG，作为 scenario 里 `expect.design.reference` 的来源。对应
 * docs/internal/UI_AUTOMATION_PLAN.md §4.4 / §6。
 *
 * 用法:
 *   bun e2e/pencil_export.ts <filePath> <nodeId> <outputDir> [--scale 2]
 *   bun e2e/pencil_export.ts --self-test
 *
 * 依赖：Pencil 桌面端在跑，且 MCP server 可用（默认路径在 Pen.app 内）。
 * 产物命名：<outputDir>/<nodeId>.png（与 export_nodes 约定一致）。
 */

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { existsSync, mkdirSync } from "node:fs";

const DEFAULT_PENCIL_MCP = "/Applications/Pen.app/Contents/Resources/app.asar.unpacked/out/mcp-server-darwin-arm64";

// ── MCP stdio 客户端（newline-delimited JSON-RPC 2.0）──

interface McpClient {
  request(method: string, params?: unknown): Promise<any>;
  close(): void;
}

function spawnMcpClient(command: string, args: string[]): McpClient {
  const proc = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
  const rl = createInterface({ input: proc.stdout });
  let nextId = 1;
  const pending = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();

  rl.on("line", (line) => {
    let msg: any;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id === undefined) return; // 通知（无 id）忽略
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(msg.error?.message ?? JSON.stringify(msg.error)));
    else p.resolve(msg.result);
  });

  proc.on("exit", (code) => {
    for (const [, p] of pending) p.reject(new Error(`MCP server exited (code ${code})`));
    pending.clear();
  });

  return {
    request(method, params) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
      });
    },
    close() { try { proc.kill(); } catch {} },
  };
}

// ── export_nodes ──

export interface ExportNodesOpts {
  filePath: string;
  nodeIds: string[];
  outputDir: string;
  scale?: number;
}

export async function exportNodes(
  opts: ExportNodesOpts,
  command: string = DEFAULT_PENCIL_MCP,
  args: string[] = ["--app", "desktop", "--agent", "zenit-pencil-export"],
): Promise<string[]> {
  mkdirSync(opts.outputDir, { recursive: true });
  const client = spawnMcpClient(command, args);
  try {
    await client.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "zenit-pencil-export", version: "1.0.0" },
    });
    const result = await client.request("tools/call", {
      name: "export_nodes",
      arguments: {
        filePath: opts.filePath,
        outputDir: opts.outputDir,
        nodeIds: opts.nodeIds,
        scale: opts.scale ?? 2,
      },
    });
    return extractPngPaths(result);
  } finally {
    client.close();
  }
}

/** 尽力从 MCP 返回里抽取 .png 路径（不假设 result 结构，递归扫，正则抽 path-like token）。 */
function extractPngPaths(result: unknown): string[] {
  const paths: string[] = [];
  const walk = (n: any) => {
    if (typeof n === "string") {
      for (const m of n.matchAll(/[^\s"'`]+\.png/g)) paths.push(m[0]);
      return;
    }
    if (Array.isArray(n)) { for (const x of n) walk(x); return; }
    if (n && typeof n === "object") { for (const v of Object.values(n)) walk(v); }
  };
  walk(result);
  return [...new Set(paths)];
}

// ── self-test（用 mock echo server 验证 JSON-RPC 往返 + 路径抽取）──

const MOCK_SERVER = `
process.stdin.on("data", (chunk) => {
  for (const line of chunk.toString().split("\\n")) {
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    let result;
    if (msg.method === "initialize") result = { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "mock", version: "1" } };
    else if (msg.method === "tools/call") result = { content: [{ type: "text", text: "exported /tmp/zenit_out/node1.png" }] };
    else result = {};
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\\n");
  }
});
`;

async function selfTest(): Promise<void> {
  const proc = spawn("bun", ["-e", MOCK_SERVER], { stdio: ["pipe", "pipe", "inherit"] });
  // 直接复用 spawnMcpClient 走同一条 stdio 通路（注入 mock server 进程）
  const rl = createInterface({ input: proc.stdout });
  let nextId = 1;
  const pending = new Map<number, any>();
  rl.on("line", (line) => {
    const msg = JSON.parse(line);
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p.resolve(msg.result); }
  });
  const req = (method: string, params: unknown) => new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, { resolve });
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });

  const init = await req("initialize", {}) as any;
  if (init.protocolVersion !== "2024-11-05") throw new Error("initialize self-test failed");
  const call = await req("tools/call", {}) as any;
  const paths = extractPngPaths(call);
  if (paths.length !== 1 || paths[0] !== "/tmp/zenit_out/node1.png") {
    throw new Error(`extractPngPaths self-test failed: ${JSON.stringify(paths)}`);
  }
  proc.kill();
  console.log("pencil_export self-test: PASS");
}

// ── CLI ──

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  const positional = args.filter((a) => !a.startsWith("--"));
  if (positional.length !== 3) {
    console.error("usage: bun e2e/pencil_export.ts <filePath> <nodeId> <outputDir> [--scale 2]");
    process.exit(64);
  }
  const scaleIdx = args.indexOf("--scale");
  const scale = scaleIdx >= 0 ? Number(args[scaleIdx + 1] ?? 2) : 2;
  const [filePath, nodeId, outputDir] = positional;
  if (!existsSync(filePath)) { console.error(`.pen not found: ${filePath}`); process.exit(66); }

  console.log(`==> export_nodes ${filePath} @${nodeId} → ${outputDir} (scale ${scale})`);
  const paths = await exportNodes({ filePath, nodeIds: [nodeId], outputDir, scale });
  if (paths.length === 0) {
    console.error("export_nodes 未返回任何 PNG 路径（检查 Pencil 是否在跑、nodeId 是否正确）");
    process.exit(1);
  }
  for (const p of paths) console.log(`   → ${p}`);
}

if (import.meta.main) main().catch((e) => {
  console.error("pencil_export failed:", e?.message ?? e);
  process.exit(1);
});
