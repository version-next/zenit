/// png.ts — 最小 PNG 解码器（8-bit RGB/RGBA、非交错），供 e2e 做像素级断言。
/// 只依赖 Bun.inflateSync；harness 截图固定为此格式。
import { readFileSync } from "node:fs";
import { inflateSync } from "node:zlib";

export interface DecodedPng {
  width: number;
  height: number;
  channels: number; // 3 (RGB) or 4 (RGBA)
  pixels: Uint8Array; // width*height*channels, 行优先
}

export function decodePng(path: string): DecodedPng {
  const buf = readFileSync(path);
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error(`${path}: 非 PNG`);
  let off = 8;
  let width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat: Uint8Array[] = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      if (data[12] !== 0) throw new Error("不支持交错 PNG");
      if (bitDepth !== 8) throw new Error(`不支持 bitDepth=${bitDepth}`);
      if (colorType !== 2 && colorType !== 6) throw new Error(`不支持 colorType=${colorType}`);
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") break;
    off += 12 + len;
  }
  const channels = colorType === 6 ? 4 : 3;
  const compressed = Buffer.concat(idat);
  const raw = inflateSync(compressed);
  const stride = width * channels;
  const pixels = new Uint8Array(width * height * channels);
  // unfilter
  let ri = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[ri++];
    const row = pixels.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const rawByte = raw[ri + x];
      const a = x >= channels ? row[x - channels] : 0;
      const b = prev ? prev[x] : 0;
      const c = x >= channels && prev ? prev[x - channels] : 0;
      let v: number;
      switch (filter) {
        case 0: v = rawByte; break;
        case 1: v = rawByte + a; break;
        case 2: v = rawByte + b; break;
        case 3: v = rawByte + ((a + b) >> 1); break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          const pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
          v = rawByte + pred;
          break;
        }
        default: throw new Error(`未知 filter ${filter}`);
      }
      row[x] = v & 0xff;
    }
    ri += stride;
  }
  return { width, height, channels, pixels };
}

/// 统计矩形区域内亮度低于 threshold 的像素数（即"深色文字/图形"像素）。
/// rect 为逻辑坐标，scale 为截图物理/逻辑比（默认自动按 png 宽 / logicalWidth 推）。
export function countDarkPixels(
  png: DecodedPng,
  rect: { x: number; y: number; w: number; h: number },
  scale: number,
  threshold = 100,
): number {
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let count = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      const lum = 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
      if (lum < threshold) count++;
    }
  }
  return count;
}

/// 统计区域内「与背景色不同」的像素数。
///
/// `countDarkPixels` 的 threshold=100 是近黑判据，只适合深色文字。浅色图形
/// （spinner 的细线圈、skeleton 的浅灰占位块）在正常渲染下也只有个位数深色
/// 像素 —— 用深色判据会把「画对了」误判成「像素空白」。
///
/// 这个函数改问「这块区域是不是一片纯背景」：与背景色的亮度差超过 `minDelta`
/// 即计数。它能同时抓住深色文字缺失和浅色图形缺失，代价是需要估计背景色
/// （取区域四角亮度的中位数，见下）。
export function countNonBackgroundPixels(
  png: DecodedPng,
  rect: { x: number; y: number; w: number; h: number },
  scale: number,
  minDelta = 8,
): number {
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  if (x1 <= x0 || y1 <= y0) return 0;

  const lumAt = (x: number, y: number): number => {
    const i = (y * png.width + x) * png.channels;
    return 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
  };

  // 背景色取四角的中位数：四角落在图形上的概率远低于落在背景上，
  // 取中位数还能容忍其中一两个角恰好被图形覆盖。
  const corners = [
    lumAt(x0, y0),
    lumAt(x1 - 1, y0),
    lumAt(x0, y1 - 1),
    lumAt(x1 - 1, y1 - 1),
  ].sort((a, b) => a - b);
  const bg = (corners[1] + corners[2]) / 2;

  let count = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      if (Math.abs(lumAt(x, y) - bg) >= minDelta) count++;
    }
  }
  return count;
}
