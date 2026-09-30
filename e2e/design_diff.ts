/**
 * design_diff.ts — 设计稿 vs 实现 的结构化像素比对。
 *
 * 改动后请跑 `--self-test`（6 个用例）。
 *
 * 与 `golden_compare.ts` 的分工（不要混用）：
 *   - golden_compare: 回归门禁。同尺寸基线，尺寸不等直接 throw，只给两个全局标量。
 *   - design_diff（本文件）: 还原辅助。**尺寸天然不同**（设计稿 2x 导出 vs 应用截图），
 *     自动对齐尺寸，并输出「差在哪、差多少、往哪个方向差」，让 AI 不必读图就能改。
 *
 * 设计目标：输出必须能直接驱动下一步修改。所以不只给分数，还给：
 *   - 网格热力图：哪一块差（8x8 网格 + ASCII 可视化）
 *   - 边缘投影差：行/列内容边界的偏移量 → 直接对应 padding/gap/位置错误
 *   - 主色差异：调色板比对 → 直接对应用错 token
 *
 * 用法:
 *   bun e2e/design_diff.ts DESIGN.png ACTUAL.png [--json] [--grid N] [--top N]
 *   bun e2e/design_diff.ts --self-test
 */
import { existsSync } from "node:fs";
import { decodePng, type DecodedPng } from "./png";

// ── 基础工具 ──

/**
 * 把带 alpha 的图合成到不透明底色上。
 *
 * 这一步是必须的，不是可选优化：pencil 的 `export_nodes` 导出的组件 PNG
 * 通常带透明背景，透明像素的 RGB 往往是 (0,0,0)。若直接比 RGB，设计稿会被
 * 当成"黑底"，而应用截图是白底 —— 结果是 ~99% 像素差 + RMSE 250 的假报警，
 * 而两张图人眼看几乎一样。实测踩过这个坑，故有下面的 self-test 兜底。
 */
export function flattenOnto(png: DecodedPng, matte: [number, number, number]): DecodedPng {
  if (png.channels < 4) return png;
  const out = new Uint8Array(png.width * png.height * 3);
  for (let i = 0; i < png.width * png.height; i++) {
    const a = png.pixels[i * 4 + 3] / 255;
    for (let c = 0; c < 3; c++) {
      out[i * 3 + c] = Math.round(png.pixels[i * 4 + c] * a + matte[c] * (1 - a));
    }
  }
  return { width: png.width, height: png.height, channels: 3, pixels: out };
}

/** 双线性重采样到目标尺寸。设计稿导出常是 2x，截图是 Retina 2x，尺寸仍可能不等。 */
export function resample(src: DecodedPng, width: number, height: number): DecodedPng {
  if (src.width === width && src.height === height) return src;
  const out = new Uint8Array(width * height * 3);
  const xRatio = src.width / width;
  const yRatio = src.height / height;
  for (let y = 0; y < height; y++) {
    const sy = Math.min(src.height - 1, (y + 0.5) * yRatio - 0.5);
    const y0 = Math.max(0, Math.floor(sy));
    const y1 = Math.min(src.height - 1, y0 + 1);
    const fy = sy - y0;
    for (let x = 0; x < width; x++) {
      const sx = Math.min(src.width - 1, (x + 0.5) * xRatio - 0.5);
      const x0 = Math.max(0, Math.floor(sx));
      const x1 = Math.min(src.width - 1, x0 + 1);
      const fx = sx - x0;
      for (let c = 0; c < 3; c++) {
        const p00 = src.pixels[(y0 * src.width + x0) * src.channels + c];
        const p01 = src.pixels[(y0 * src.width + x1) * src.channels + c];
        const p10 = src.pixels[(y1 * src.width + x0) * src.channels + c];
        const p11 = src.pixels[(y1 * src.width + x1) * src.channels + c];
        const top = p00 + (p01 - p00) * fx;
        const bot = p10 + (p11 - p10) * fx;
        out[(y * width + x) * 3 + c] = Math.round(top + (bot - top) * fy);
      }
    }
  }
  return { width, height, channels: 3, pixels: out };
}

function luma(png: DecodedPng, idx: number): number {
  const o = idx * png.channels;
  return 0.299 * png.pixels[o] + 0.587 * png.pixels[o + 1] + 0.114 * png.pixels[o + 2];
}

// ── 1. 网格热力图：差异定位到区块 ──

export interface GridCell {
  row: number;
  col: number;
  /** 该格平均通道差 (0-255) */
  delta: number;
  /** 该格超阈值像素占比 */
  changedRatio: number;
}

export function gridDiff(a: DecodedPng, b: DecodedPng, grid: number, threshold: number): GridCell[] {
  const cells: GridCell[] = [];
  const cellW = a.width / grid;
  const cellH = a.height / grid;
  for (let row = 0; row < grid; row++) {
    for (let col = 0; col < grid; col++) {
      const x0 = Math.floor(col * cellW), x1 = Math.floor((col + 1) * cellW);
      const y0 = Math.floor(row * cellH), y1 = Math.floor((row + 1) * cellH);
      let sum = 0, changed = 0, count = 0;
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
          const i = y * a.width + x;
          let maxDelta = 0;
          for (let c = 0; c < 3; c++) {
            const d = Math.abs(a.pixels[i * a.channels + c] - b.pixels[i * b.channels + c]);
            sum += d;
            if (d > maxDelta) maxDelta = d;
          }
          if (maxDelta > threshold) changed++;
          count++;
        }
      }
      if (count === 0) continue;
      cells.push({ row, col, delta: sum / (count * 3), changedRatio: changed / count });
    }
  }
  return cells;
}

/** ASCII 热力图。空=一致，数字越大差越多，# 为最严重。 */
export function renderHeatmap(cells: GridCell[], grid: number): string {
  const rows: string[] = [];
  for (let r = 0; r < grid; r++) {
    let line = "";
    for (let c = 0; c < grid; c++) {
      const cell = cells.find((x) => x.row === r && x.col === c);
      const v = cell ? cell.changedRatio : 0;
      line += v === 0 ? " ·" : v < 0.05 ? " 1" : v < 0.15 ? " 2" : v < 0.3 ? " 4"
        : v < 0.5 ? " 6" : v < 0.75 ? " 8" : " #";
    }
    rows.push(line);
  }
  return rows.join("\n");
}

// ── 2. 边缘投影：把差异翻译成「偏移了多少像素」 ──

/**
 * 内容边界投影。对每行/每列求「非背景像素」数量，得到内容分布曲线。
 * 两张图的曲线错位量 = 布局偏移量，直接对应 padding/gap/margin 错误。
 */
export function projection(png: DecodedPng, axis: "row" | "col", bgLuma: number): number[] {
  const n = axis === "row" ? png.height : png.width;
  const m = axis === "row" ? png.width : png.height;
  const out = new Array<number>(n).fill(0);
  for (let i = 0; i < n; i++) {
    let count = 0;
    for (let j = 0; j < m; j++) {
      const idx = axis === "row" ? i * png.width + j : j * png.width + i;
      if (Math.abs(luma(png, idx) - bgLuma) > 24) count++;
    }
    out[i] = count;
  }
  return out;
}

/** 估计背景亮度：取四角与边缘中点的中位数。 */
export function estimateBackgroundLuma(png: DecodedPng): number {
  const pts = [
    [0, 0], [png.width - 1, 0], [0, png.height - 1], [png.width - 1, png.height - 1],
    [Math.floor(png.width / 2), 0], [0, Math.floor(png.height / 2)],
  ];
  const vals = pts.map(([x, y]) => luma(png, y * png.width + x)).sort((p, q) => p - q);
  return vals[Math.floor(vals.length / 2)];
}

/** 互相关求最佳整体位移（±maxShift），返回位移量与该位移下的残差。 */
export function bestShift(a: number[], b: number[], maxShift: number): { shift: number; residual: number } {
  let best = { shift: 0, residual: Infinity };
  for (let s = -maxShift; s <= maxShift; s++) {
    let sum = 0, count = 0;
    for (let i = 0; i < a.length; i++) {
      const j = i + s;
      if (j < 0 || j >= b.length) continue;
      sum += Math.abs(a[i] - b[j]);
      count++;
    }
    if (count === 0) continue;
    const residual = sum / count;
    if (residual < best.residual) best = { shift: s, residual };
  }
  return best;
}

/** 内容包围盒：内容区的首尾非背景行/列，用于比对整体尺寸与位置。 */
export function contentBounds(proj: number[]): { start: number; end: number } {
  const peak = Math.max(...proj);
  const floor = Math.max(1, peak * 0.02);
  let start = proj.findIndex((v) => v > floor);
  let end = proj.length - 1 - [...proj].reverse().findIndex((v) => v > floor);
  if (start < 0) { start = 0; end = 0; }
  return { start, end };
}

// ── 3. 调色板比对：抓「用错颜色 token」 ──

export interface PaletteEntry { hex: string; ratio: number; }

/** 量化到 5 位/通道后统计主色。 */
export function palette(png: DecodedPng, topN: number): PaletteEntry[] {
  const hist = new Map<number, number>();
  const total = png.width * png.height;
  for (let i = 0; i < total; i++) {
    const o = i * png.channels;
    const key = ((png.pixels[o] >> 3) << 10) | ((png.pixels[o + 1] >> 3) << 5) | (png.pixels[o + 2] >> 3);
    hist.set(key, (hist.get(key) ?? 0) + 1);
  }
  return [...hist.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, topN)
    .map(([key, n]) => {
      const r = ((key >> 10) & 31) << 3, g = ((key >> 5) & 31) << 3, b = (key & 31) << 3;
      const hex = "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("");
      return { hex, ratio: n / total };
    });
}

function hexToRgb(hex: string): [number, number, number] {
  return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
}

/** 为设计稿主色找实现中最接近的色，距离大 = 颜色用错。 */
export function paletteDiff(design: PaletteEntry[], actual: PaletteEntry[]) {
  return design.map((d) => {
    const [dr, dg, db] = hexToRgb(d.hex);
    let best = { hex: "", dist: Infinity };
    for (const a of actual) {
      const [ar, ag, ab] = hexToRgb(a.hex);
      const dist = Math.sqrt((dr - ar) ** 2 + (dg - ag) ** 2 + (db - ab) ** 2);
      if (dist < best.dist) best = { hex: a.hex, dist };
    }
    return { design: d.hex, designRatio: d.ratio, nearestActual: best.hex, distance: best.dist };
  });
}

// ── 汇总 ──

export interface DiffReport {
  designSize: string;
  actualSize: string;
  comparedAt: string;
  changedRatio: number;
  rmse: number;
  score: number;
  heatmap: string;
  worstCells: GridCell[];
  offset: { x: number; y: number; xResidual: number; yResidual: number };
  bounds: {
    design: { x: [number, number]; y: [number, number] };
    actual: { x: [number, number]; y: [number, number] };
  };
  paletteIssues: ReturnType<typeof paletteDiff>;
  hints: string[];
}

export function compare(
  designPng: DecodedPng,
  actualPng: DecodedPng,
  opts: { grid: number; threshold: number; top: number; matte?: [number, number, number] },
): DiffReport {
  // 先按 alpha 合成到同一底色 —— 必须在重采样与任何差值之前做。
  const matte = opts.matte ?? [255, 255, 255];
  const designFlat = flattenOnto(designPng, matte);
  const actualFlat = flattenOnto(actualPng, matte);

  // 统一到实现截图的尺寸（保留实现的真实分辨率作为坐标系）。
  const w = actualFlat.width, h = actualFlat.height;
  const design = resample(designFlat, w, h);
  const actual = actualFlat;

  let squared = 0, changed = 0;
  const pixelCount = w * h;
  for (let i = 0; i < pixelCount; i++) {
    let pixelChanged = false;
    for (let c = 0; c < 3; c++) {
      const d = Math.abs(design.pixels[i * design.channels + c] - actual.pixels[i * actual.channels + c]);
      squared += d * d;
      if (d > opts.threshold) pixelChanged = true;
    }
    if (pixelChanged) changed++;
  }
  const changedRatio = changed / pixelCount;
  const rmse = Math.sqrt(squared / (pixelCount * 3));

  const cells = gridDiff(design, actual, opts.grid, opts.threshold);
  const worstCells = [...cells].sort((a, b) => b.changedRatio - a.changedRatio).slice(0, opts.top);

  const dBg = estimateBackgroundLuma(design);
  const aBg = estimateBackgroundLuma(actual);
  const dRow = projection(design, "row", dBg), aRow = projection(actual, "row", aBg);
  const dCol = projection(design, "col", dBg), aCol = projection(actual, "col", aBg);
  const maxShift = Math.max(4, Math.floor(Math.min(w, h) * 0.1));
  const yShift = bestShift(dRow, aRow, maxShift);
  const xShift = bestShift(dCol, aCol, maxShift);

  const dRowB = contentBounds(dRow), aRowB = contentBounds(aRow);
  const dColB = contentBounds(dCol), aColB = contentBounds(aCol);

  const paletteIssues = paletteDiff(palette(design, 6), palette(actual, 12))
    .filter((p) => p.distance > 24);

  // 把数字翻译成可执行的修改建议。
  const hints: string[] = [];
  if (Math.abs(xShift.shift) >= 2) {
    hints.push(`整体水平偏移 ${xShift.shift > 0 ? "右" : "左"} ${Math.abs(xShift.shift)}px — 检查左右 padding / margin / justify`);
  }
  if (Math.abs(yShift.shift) >= 2) {
    hints.push(`整体垂直偏移 ${yShift.shift > 0 ? "下" : "上"} ${Math.abs(yShift.shift)}px — 检查上下 padding / align_items`);
  }
  const dW = dColB.end - dColB.start, aW = aColB.end - aColB.start;
  const dH = dRowB.end - dRowB.start, aH = aRowB.end - aRowB.start;
  if (Math.abs(dW - aW) >= 3) {
    hints.push(`内容宽度差 ${aW - dW}px（设计 ${dW} vs 实现 ${aW}）— 检查 width/flex/gap`);
  }
  if (Math.abs(dH - aH) >= 3) {
    hints.push(`内容高度差 ${aH - dH}px（设计 ${dH} vs 实现 ${aH}）— 检查 height/行高/gap`);
  }
  for (const p of paletteIssues.slice(0, 3)) {
    hints.push(`颜色偏差: 设计 ${p.design}（占 ${(p.designRatio * 100).toFixed(1)}%）最近实现色 ${p.nearestActual}，距离 ${p.distance.toFixed(0)} — 检查 token 取值`);
  }
  if (hints.length === 0 && changedRatio > 0.02) {
    hints.push("无整体位移/尺寸/配色偏差，差异集中在局部 — 看 worstCells 定位区块（可能是字体、圆角、阴影或图标）");
  }

  // 分数：changedRatio 与 rmse 综合，100 = 完全一致。
  const score = Math.max(0, 100 - changedRatio * 100 * 0.7 - Math.min(30, rmse));

  return {
    designSize: `${designPng.width}x${designPng.height}`,
    actualSize: `${actualPng.width}x${actualPng.height}`,
    comparedAt: `${w}x${h}`,
    changedRatio, rmse, score,
    heatmap: renderHeatmap(cells, opts.grid),
    worstCells,
    offset: { x: xShift.shift, y: yShift.shift, xResidual: xShift.residual, yResidual: yShift.residual },
    bounds: {
      design: { x: [dColB.start, dColB.end], y: [dRowB.start, dRowB.end] },
      actual: { x: [aColB.start, aColB.end], y: [aRowB.start, aRowB.end] },
    },
    paletteIssues,
    hints,
  };
}

// ── 自检 ──

function selfTest(): void {
  const solid = (w: number, h: number, rgb: [number, number, number]): DecodedPng => {
    const pixels = new Uint8Array(w * h * 3);
    for (let i = 0; i < w * h; i++) {
      pixels[i * 3] = rgb[0]; pixels[i * 3 + 1] = rgb[1]; pixels[i * 3 + 2] = rgb[2];
    }
    return { width: w, height: h, channels: 3, pixels };
  };
  const withRect = (
    base: DecodedPng, x0: number, y0: number, rw: number, rh: number, rgb: [number, number, number],
  ): DecodedPng => {
    const out = { ...base, pixels: new Uint8Array(base.pixels) };
    for (let y = y0; y < y0 + rh; y++) {
      for (let x = x0; x < x0 + rw; x++) {
        if (x < 0 || y < 0 || x >= base.width || y >= base.height) continue;
        const i = (y * base.width + x) * 3;
        out.pixels[i] = rgb[0]; out.pixels[i + 1] = rgb[1]; out.pixels[i + 2] = rgb[2];
      }
    }
    return out;
  };

  // 1. 相同图 → 满分、无提示
  const white = solid(64, 64, [255, 255, 255]);
  const a = withRect(white, 10, 10, 20, 20, [0, 0, 0]);
  const same = compare(a, a, { grid: 8, threshold: 8, top: 3 });
  if (same.changedRatio !== 0 || same.rmse !== 0) throw new Error("identical-image self-test failed");
  if (same.score !== 100) throw new Error(`identical score should be 100, got ${same.score}`);
  if (same.hints.length !== 0) throw new Error("identical image should yield no hints");

  // 2. 纯位移 → 必须报出正确方向与量级
  const shifted = withRect(white, 16, 10, 20, 20, [0, 0, 0]);
  const shiftRep = compare(a, shifted, { grid: 8, threshold: 8, top: 3 });
  if (shiftRep.offset.x !== 6) throw new Error(`expected x offset 6, got ${shiftRep.offset.x}`);
  if (shiftRep.offset.y !== 0) throw new Error(`expected y offset 0, got ${shiftRep.offset.y}`);
  if (!shiftRep.hints.some((s) => s.includes("水平偏移"))) throw new Error("shift hint missing");

  // 3. 尺寸不同也能比（自动重采样），不再 throw
  const big = solid(128, 128, [255, 255, 255]);
  const bigRect = withRect(big, 20, 20, 40, 40, [0, 0, 0]);
  const scaled = compare(bigRect, a, { grid: 8, threshold: 8, top: 3 });
  if (scaled.comparedAt !== "64x64") throw new Error("resample target should be actual size");
  if (scaled.changedRatio > 0.05) throw new Error(`2x-scaled identical content should match, got ${scaled.changedRatio}`);

  // 4. 变色 → 必须报调色板问题
  const red = withRect(white, 10, 10, 20, 20, [220, 30, 30]);
  const colorRep = compare(a, red, { grid: 8, threshold: 8, top: 3 });
  if (colorRep.paletteIssues.length === 0) throw new Error("palette diff should flag a recolor");
  if (!colorRep.hints.some((s) => s.includes("颜色偏差"))) throw new Error("color hint missing");

  // 5. 内容尺寸差 → 必须报宽度差
  const wider = withRect(white, 10, 10, 34, 20, [0, 0, 0]);
  const widthRep = compare(a, wider, { grid: 8, threshold: 8, top: 3 });
  if (!widthRep.hints.some((s) => s.includes("内容宽度差"))) throw new Error("width hint missing");

  // 6. 回归：透明背景的设计稿 vs 白底截图，必须判为「几乎一致」。
  //    这是实测踩过的真坑 —— 修复前此用例报 0.8/100、98.9% 差异像素。
  const rgbaTransparentBg = (w2: number, h2: number): DecodedPng => {
    const pixels = new Uint8Array(w2 * h2 * 4); // 全 0 = 透明且 RGB 为黑
    for (let y = 10; y < 30; y++) {
      for (let x = 10; x < 30; x++) {
        const i = (y * w2 + x) * 4;
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255; // 不透明黑内容
      }
    }
    return { width: w2, height: h2, channels: 4, pixels };
  };
  const transparentDesign = rgbaTransparentBg(64, 64);
  const whiteBgActual = withRect(white, 10, 10, 20, 20, [0, 0, 0]);
  const alphaRep = compare(transparentDesign, whiteBgActual, { grid: 8, threshold: 8, top: 3 });
  if (alphaRep.changedRatio > 0.01) {
    throw new Error(`transparent-vs-white should match after flatten, got ${(alphaRep.changedRatio * 100).toFixed(1)}% changed`);
  }
  if (alphaRep.score < 99) throw new Error(`alpha-flatten score should be ~100, got ${alphaRep.score}`);

  console.log("design_diff self-test: PASS (6 cases)");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();

  // 手动解析 positional：--json 是布尔 flag，--grid/--top/--threshold 各带一个值。
  // 旧实现 `args.filter(a => !a.startsWith("--"))` 会把 flag 的值也算进 positional
  // （如 `--grid 8` 的 `8`），导致 `--json --grid 8` 被误判为 3 个 positional → exit 64。
  const valueFlags = new Set(["--grid", "--top", "--threshold"]);
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith("--")) {
      if (valueFlags.has(a)) i++; // 消费该 flag 的值
      continue;
    }
    positional.push(a);
  }
  if (positional.length !== 2) {
    console.error("usage: bun e2e/design_diff.ts DESIGN.png ACTUAL.png [--json] [--grid N] [--top N] [--threshold N]");
    console.error("       bun e2e/design_diff.ts --self-test");
    process.exit(64);
  }
  const flag = (name: string, dflt: number): number => {
    const i = args.indexOf(`--${name}`);
    return i >= 0 && args[i + 1] ? Number(args[i + 1]) : dflt;
  };
  const [designPath, actualPath] = positional;
  for (const p of [designPath, actualPath]) {
    if (!existsSync(p)) { console.error(`file not found: ${p}`); process.exit(66); }
  }

  const report = compare(decodePng(designPath), decodePng(actualPath), {
    grid: flag("grid", 8),
    threshold: flag("threshold", 8),
    top: flag("top", 5),
  });

  if (args.includes("--json")) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(`设计稿: ${report.designSize}   实现: ${report.actualSize}   比对尺寸: ${report.comparedAt}`);
  console.log(`相似度: ${report.score.toFixed(1)}/100   差异像素: ${(report.changedRatio * 100).toFixed(2)}%   RMSE: ${report.rmse.toFixed(2)}`);
  console.log(`\n差异热力图 (· 一致 → # 严重):\n${report.heatmap}`);
  console.log(`\n内容包围盒  设计 x=[${report.bounds.design.x}] y=[${report.bounds.design.y}]`);
  console.log(`            实现 x=[${report.bounds.actual.x}] y=[${report.bounds.actual.y}]`);
  console.log(`整体位移    x=${report.offset.x}px  y=${report.offset.y}px`);
  if (report.hints.length > 0) {
    console.log(`\n可执行提示:`);
    for (const h of report.hints) console.log(`  • ${h}`);
  } else {
    console.log(`\n无显著结构差异。`);
  }
  if (report.worstCells.length > 0 && report.changedRatio > 0.005) {
    console.log(`\n差异最大的区块 (${report.worstCells.length}):`);
    for (const c of report.worstCells) {
      console.log(`  行${c.row} 列${c.col}: ${(c.changedRatio * 100).toFixed(1)}% 像素差, 平均 ${c.delta.toFixed(1)}`);
    }
  }
}

if (import.meta.main) main();
