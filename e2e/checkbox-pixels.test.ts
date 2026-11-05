import { expect, test } from "bun:test";
import { checkboxInk } from "./checkbox-pixels";

function sample(fill: number[], mark: boolean) {
  const pixels = new Uint8Array(16 * 16 * 3);
  for (let i = 0; i < pixels.length; i += 3) pixels.set(fill, i);
  if (mark) for (let x = 4; x < 12; x++) pixels.set([255, 255, 255], (8 * 16 + x) * 3);
  return checkboxInk({ width: 16, height: 16, channels: 3, pixels }, { x0: 2, y0: 2, x1: 14, y1: 14 });
}

test("checkbox ink is independent of black or Windows blue accent", () => {
  for (const fill of [[26, 26, 26], [59, 96, 184]]) {
    const result = sample(fill, true);
    expect(result.ink).toBe(8);
    expect(result.background).toBe(136);
  }
});

test("missing mark, missing control and blank white surface cannot pass", () => {
  for (const fill of [[26, 26, 26], [59, 96, 184], [255, 255, 255]]) {
    expect(sample(fill, false).ink).toBe(0);
  }
  expect(sample([255, 255, 255], true).ink).toBe(0);
});
