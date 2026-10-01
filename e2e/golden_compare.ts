/// Fail-closed perceptual comparison for Storybook PNG baselines.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { decodePng, type DecodedPng } from "./png";

export interface GoldenManifest {
  schema_version: 1;
  pixel_delta_threshold: number;
  max_changed_ratio: number;
  max_rmse: number;
  files: string[];
}

export function comparePixels(a: DecodedPng, b: DecodedPng, threshold: number) {
  if (a.width !== b.width || a.height !== b.height) {
    throw new Error(`dimension mismatch: ${a.width}x${a.height} vs ${b.width}x${b.height}`);
  }
  let squared = 0;
  let changed = 0;
  const pixelCount = a.width * a.height;
  for (let pixel = 0; pixel < pixelCount; pixel++) {
    let pixelChanged = false;
    for (let channel = 0; channel < 3; channel++) {
      const av = a.pixels[pixel * a.channels + channel];
      const bv = b.pixels[pixel * b.channels + channel];
      const delta = Math.abs(av - bv);
      squared += delta * delta;
      if (delta > threshold) pixelChanged = true;
    }
    if (pixelChanged) changed++;
  }
  return {
    changed_ratio: changed / pixelCount,
    rmse: Math.sqrt(squared / (pixelCount * 3)),
  };
}

/** 单 case golden 阈值配置（从 manifest 抽出，供库调用方直接构造）。 */
export interface GoldenConfig {
  pixel_delta_threshold: number;
  max_changed_ratio: number;
  max_rmse: number;
}

/** 单 case 比较结果。dimension mismatch / 解码失败 -> ok=false + error（不 throw）。 */
export interface GoldenResult {
  ok: boolean;
  changed_ratio: number | null;
  rmse: number | null;
  error?: string;
}

/** 对两张已解码 PNG 做 golden 比较，返回结构化结果（不 throw，失败进 error）。 */
export function compareGolden(baseline: DecodedPng, actual: DecodedPng, config: GoldenConfig): GoldenResult {
  try {
    const { changed_ratio, rmse } = comparePixels(baseline, actual, config.pixel_delta_threshold);
    const ok = changed_ratio <= config.max_changed_ratio && rmse <= config.max_rmse;
    return { ok, changed_ratio, rmse };
  } catch (err) {
    return { ok: false, changed_ratio: null, rmse: null, error: err instanceof Error ? err.message : String(err) };
  }
}

/** 对两个 PNG 文件路径做 golden 比较。缺文件/解码失败 -> ok=false + error。 */
export function compareGoldenFiles(baselinePath: string, actualPath: string, config: GoldenConfig): GoldenResult {
  for (const p of [baselinePath, actualPath]) {
    if (!existsSync(p)) return { ok: false, changed_ratio: null, rmse: null, error: `missing file: ${p}` };
  }
  return compareGolden(decodePng(baselinePath), decodePng(actualPath), config);
}

function selfTest(): void {
  const image = (values: number[]): DecodedPng => ({
    width: 2, height: 1, channels: 3, pixels: Uint8Array.from(values),
  });
  const exact = comparePixels(image([0, 1, 2, 10, 20, 30]), image([0, 1, 2, 10, 20, 30]), 2);
  if (exact.changed_ratio !== 0 || exact.rmse !== 0) throw new Error("exact-image self-test failed");
  const delta = comparePixels(image([0, 0, 0, 0, 0, 0]), image([3, 0, 0, 0, 0, 0]), 2);
  if (delta.changed_ratio !== 0.5 || Math.abs(delta.rmse - Math.sqrt(1.5)) > 1e-9) {
    throw new Error("delta metric self-test failed");
  }

  // 库入口（compareGolden / compareGoldenFiles）必须把失败落进 error，而非 throw。
  const config: GoldenConfig = { pixel_delta_threshold: 2, max_changed_ratio: 0.01, max_rmse: 0.5 };
  const ok = compareGolden(image([0, 0, 0, 0, 0, 0]), image([0, 0, 0, 0, 0, 0]), config);
  if (!ok.ok || ok.changed_ratio !== 0 || ok.rmse !== 0) throw new Error("compareGolden identical self-test failed");
  const bad = compareGolden(image([0, 0, 0, 0, 0, 0]), image([200, 0, 0, 0, 0, 0]), config);
  if (bad.ok || bad.error !== undefined) throw new Error("compareGolden mismatch self-test failed");
  const dim = compareGolden(
    { width: 2, height: 1, channels: 3, pixels: new Uint8Array(6) },
    { width: 3, height: 1, channels: 3, pixels: new Uint8Array(9) },
    config,
  );
  if (dim.ok || dim.error === undefined) throw new Error("compareGolden dimension-mismatch self-test failed");
  const missing = compareGoldenFiles("/nonexistent/a.png", "/nonexistent/b.png", config);
  if (missing.ok || missing.error === undefined) throw new Error("compareGoldenFiles missing self-test failed");

  console.log("storybook golden comparator self-test: PASS");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  if (args.length !== 3) {
    throw new Error("usage: bun e2e/golden_compare.ts MANIFEST BASELINE_DIR CURRENT_DIR");
  }
  const [manifestPath, baselineDir, currentDir] = args;
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as GoldenManifest;
  if (manifest.schema_version !== 1 || !Array.isArray(manifest.files) || manifest.files.length === 0) {
    throw new Error("golden manifest must be schema v1 with a non-empty file list");
  }
  if (manifest.pixel_delta_threshold < 0 || manifest.max_changed_ratio < 0 || manifest.max_changed_ratio > 1 || manifest.max_rmse < 0) {
    throw new Error("golden thresholds are out of range");
  }

  const config: GoldenConfig = {
    pixel_delta_threshold: manifest.pixel_delta_threshold,
    max_changed_ratio: manifest.max_changed_ratio,
    max_rmse: manifest.max_rmse,
  };

  const seen = new Set<string>();
  let failed = false;
  for (const file of manifest.files) {
    if (!/^[A-Za-z0-9._-]+\.png$/.test(file) || seen.has(file)) throw new Error(`invalid or duplicate golden name: ${file}`);
    seen.add(file);
    const result = compareGoldenFiles(join(baselineDir, file), join(currentDir, file), config);
    if (result.error) {
      console.log(`FAIL ${file} ${result.error}`);
      failed = true;
      continue;
    }
    console.log(`${result.ok ? "PASS" : "FAIL"} ${file} changed=${((result.changed_ratio ?? 0) * 100).toFixed(4)}% rmse=${(result.rmse ?? 0).toFixed(4)}`);
    if (!result.ok) failed = true;
  }
  if (failed) process.exit(1);
}

if (import.meta.main) main();
