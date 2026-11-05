type Image = { width: number; height: number; channels: number; pixels: Uint8Array };
type Bounds = { x0: number; y0: number; x1: number; y1: number };

// Infer the solid fill from the most common interior color. The selected
// control uses the current accent, which need not be black (Windows is blue).
export function checkboxInk(png: Image, bounds: Bounds) {
  const colors = new Map<number, number>();
  const samples: number[] = [];
  for (let y = bounds.y0; y < bounds.y1; y++) for (let x = bounds.x0; x < bounds.x1; x++) {
    const i = (y * png.width + x) * png.channels;
    const rgb = (png.pixels[i] << 16) | (png.pixels[i + 1] << 8) | png.pixels[i + 2];
    samples.push(rgb);
    colors.set(rgb, (colors.get(rgb) ?? 0) + 1);
  }
  const fill = [...colors].sort((a, b) => b[1] - a[1])[0]?.[0] ?? 0;
  const channels = (rgb: number) => [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255];
  const base = channels(fill), brightness = (base[0] + base[1] + base[2]) / 3;
  let ink = 0, background = 0;
  for (const rgb of samples) {
    const c = channels(rgb);
    if ((c[0] + c[1] + c[2]) / 3 >= brightness + 60) ink++;
    if (c.every((value, index) => Math.abs(value - base[index]) <= 3)) background++;
  }
  return { ink, background, fill: base };
}
