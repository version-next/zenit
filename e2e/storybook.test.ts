/// storybook.test.ts — 全 41 组件 e2e：视觉（截图）+ log 数据值双重验证。
///
/// 每个组件：clickTestId("nav.<key>") 切换 → 收集 story 子树全部文本 →
/// 断言**预期数据值**全部出现（log 数据值验证，证明内容真正渲染出而非空面板）
/// → screenshot 落 session 目录（视觉验证，截图非空 + 供人工/后续基线核验）。
/// 部分交互类组件额外交互后再断言状态值 + 截图。
import {
  stats,
  health,
  focused,
  query,
  tree,
  clickTestId,
  clickAt,
  mouseDown,
  mouseMove,
  mouseUp,
  key,
  screenPos,
  screenshot,
  waitForServerReady,
  waitFor,
  sleep,
  type_,
  inputState,
  imePreedit,
  imeCommit,
  scrollAt,
  magnifyAt,
  dragAt,
  resizeWindow,
  resetTiming,
  getE2eTimeoutMs,
} from "./client";
import { test, run, assert, getSessionDir, appendLog } from "./runner";
import { statSync } from "node:fs";
import { decodePng, countDarkPixels, countNonBackgroundPixels } from "./png";

/// 像素级验证：截图中 rect 区域必须有足量"深色"像素（文字/图形真的画出来了）。
/// 防"布局树正常但 GPU 像素空白"类 bug（settle 帧 Modal 空白面板曾漏过 49/49）。
/// 浅色图形专用：断言区域不是一片纯背景。
///
/// assertRegionHasInk 的 countDarkPixels 用近黑判据（lum < 100），对 spinner
/// 的细线圈、skeleton 的浅灰占位块不成立 —— 实测正常渲染下 spinner 只有 24 个
/// 深色像素、skeleton 是 0，用深色判据会把「画对了」误判成「像素空白」。
function assertRegionNotBlank(pngPath: string, rect: { x: number; y: number; w: number; h: number }, label: string, minPixels = 200): void {
  const png = decodePng(pngPath);
  const scale = png.width / 1100;
  const n = countNonBackgroundPixels(png, rect, scale);
  appendLog(`  ${label}: non_bg_pixels=${n} (min=${minPixels})`);
  assert(n >= minPixels, `${label} 区域是一片纯背景（non_bg=${n} < ${minPixels}）— 图形没画出来`);
}

function assertRegionHasInk(pngPath: string, rect: { x: number; y: number; w: number; h: number }, label: string, minDark = 200): void {
  const png = decodePng(pngPath);
  const scale = png.width / 1100; // 窗口逻辑宽 1100
  const dark = countDarkPixels(png, rect, scale);
  appendLog(`  ${label}: dark_pixels=${dark} (min=${minDark})`);
  assert(dark >= minDark, `${label} 区域像素级空白（dark=${dark} < ${minDark}）— 内容没画出来`);
}

const DIR = getSessionDir();

/// 读 rect 中心像素的平均 RGB（3x3 均值抹掉抗锯齿噪声）。
function centerPixel(pngPath: string, rect: { x: number; y: number; w: number; h: number }): [number, number, number] {
  const png = decodePng(pngPath);
  const scale = png.width / 1100;
  const cx = Math.round((rect.x + rect.w / 2) * scale);
  const cy = Math.round((rect.y + rect.h / 2) * scale);
  let r = 0, g = 0, b = 0, n = 0;
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      const i = ((cy + dy) * png.width + (cx + dx)) * png.channels;
      r += png.pixels[i]; g += png.pixels[i + 1]; b += png.pixels[i + 2]; n++;
    }
  }
  return [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
}

/// 扫 rect 找最深（R+G+B 最小）的像素。用于采样文字笔画本身 —— 文本节点的
/// 几何中心常常落在字母之间的背景上，取中心会测到背景而不是字形。
function darkestPixel(pngPath: string, rect: { x: number; y: number; w: number; h: number }): [number, number, number] {
  const png = decodePng(pngPath);
  const scale = png.width / 1100;
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let best: [number, number, number] = [255, 255, 255];
  let bestSum = 766;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      const r = png.pixels[i], g = png.pixels[i + 1], b = png.pixels[i + 2];
      const sum = r + g + b;
      if (sum < bestSum) { bestSum = sum; best = [r, g, b]; }
    }
  }
  return best;
}

/// 统计 rect 内"有墨"的列分布。用于 RTL 验收：字形反向重叠时，
/// 墨迹会挤成很窄一段，而正确铺开时墨迹跨越节点宽度的大部分。
/// 返回 { first, last, span, cols, width } —— 均为 rect 内的相对逻辑列。
function inkColumns(
  pngPath: string,
  rect: { x: number; y: number; w: number; h: number },
  threshold = 160,
): { first: number; last: number; span: number; cols: number; width: number } {
  const png = decodePng(pngPath);
  const scale = png.width / 1100;
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let first = -1, last = -1, cols = 0;
  const mass: number[] = [];
  for (let x = x0; x < x1; x++) {
    let inked = false;
    let m = 0;
    for (let y = y0; y < y1; y++) {
      const i = (y * png.width + x) * png.channels;
      // 深色笔画（文字色是纯黑）落在浅色背景上。
      if (png.pixels[i] < threshold && png.pixels[i + 1] < threshold && png.pixels[i + 2] < threshold) {
        inked = true;
        m += threshold - png.pixels[i];
      }
    }
    mass.push(m);
    if (inked) {
      if (first < 0) first = x - x0;
      last = x - x0;
      cols++;
    }
  }
  // 墨量质心，归一化到墨迹跨度内的 0..1。1 = 墨集中在右端。
  // 这是**字形顺序**的指纹：同一串文字正序/逆序渲染，墨量分布左右镜像，
  // 质心随之翻转。跨度/密度类判据对"顺序反了但仍均匀铺开"完全无感，
  // 质心才能抓住 —— 这正是 RTL 被逐码点切碎时的真实failure mode。
  let total = 0, acc = 0;
  for (let i = 0; i < mass.length; i++) { total += mass[i]; acc += mass[i] * i; }
  const centroid = total > 0 && last > first ? (acc / total - first) / (last - first) : 0.5;
  return { first, last, span: last - first + 1, cols, width: x1 - x0, centroid };
}

function assertColorNear(actual: [number, number, number], expected: [number, number, number], label: string, tol = 12): void {
  const d = Math.max(Math.abs(actual[0] - expected[0]), Math.abs(actual[1] - expected[1]), Math.abs(actual[2] - expected[2]));
  appendLog(`  ${label}: rgb=(${actual.join(",")}) expect=(${expected.join(",")}) maxdiff=${d}`);
  assert(d <= tol, `${label} 颜色不符: 实际(${actual.join(",")}) 期望(${expected.join(",")}) 容差${tol}`);
}

// 每组件预期出现在 story 子树里的数据值（文本）。这些值证明组件真正渲染了
// 内容（不是空面板）。与 stories.zig 里写的值一一对应。
const EXPECT: Record<string, string[]> = {
  button: ["Primary", "Secondary", "Ghost", "Danger", "Link", "Download", "Saving…", "Loading", "Normal", "Disabled", "Block primary"],
  checkbox: ["Unchecked", "Checked", "Indeterminate", "Disabled", "changed"],
  switch: ["Off", "On", "Disabled"],
  radio: ["Selected", "Unselected", "Option X", "Option Y", "Option Z"],
  slider: ["40.0", "5.0"],
  input: ["Types", "Name", "Email", "Password", "Your name", "you@example.com", "Sizes", "Search", "Required", "With helper", "3–20 characters", "With error", "This field is invalid", "Readonly", "Read only value", "Disabled"],
  textarea: ["Notes", "With helper", "Max 500 characters", "With error", "Please write more", "Disabled"],
  select: ["Select", "With icon", "Clearable", "Searchable", "Multiple · LG", "Multiple searchable · XS", "Option 1"],
  combobox: ["Fruit", "Type to search fruit"],
  badge: ["info", "success", "warning", "error", "Online", "Error", "Sizes"],
  tag: ["neutral", "accent", "success", "warning", "danger", "info", "Sizes", "Small", "Medium", "Default", "Outline", "Closable"],
  chip: ["Variants", "Default", "Active", "Outline", "Disabled", "Closable", "Sizes", "With icon", "Starred", "Folder"],
  card: ["Variants", "Default", "Outlined", "Elevated", "Card with body", "Body content goes here.", "States", "Selected", "Hoverable", "Interactive", "No padding"],
  glassbox: ["Toolbar", "Tab bar", "Continue", "Regular", "Interactive", "hover / press me", "Clear", "Backdrop shows through."],
  glasslab: ["Drag me", "warp_gain", "bezel_width", "magnification"],
  glassedge: ["Glass panels flush with the window edges"],
  glassislands: ["Island first", "Island second", "content below the slab"],
  glassmotion: ["Morph", "Floating glass toolbar", "Scroll +80"],
  glasschrome: ["Scroll +90", "Scroll −90", "Ship v1.0", "blur 20"],
  canvasevents: ["Canvas events", "scroll (none)", "magnify (none)", "drag (none)", "clip (none)", "Clipboard PNG roundtrip"],
  drag: ["state: idle", "clicks: 0", "width: 240px", "Horizontal resize"],
  // CORE_REVIEW_2026-08-16 回归锚 story（数字会随交互变化，只断言稳定前缀）
  multiclick: ["Gesture arena", "single:", "double:", "triple:", "long:", "click / double-click / hold"],
  animctl: ["Play yoyo", "Play timeline", "Reverse timeline", "KF reset", "KF +1s", "yoyo: state=", "tl: state=", "kf: loops=", "spring: ticks="],
  divider: ["Styles", "Labeled", "LEFT", "OR", "RIGHT", "Vertical", "Left", "Middle", "Right"],
  stack: ["A", "B", "C", "First", "Second", "Third"],
  layoutbox: ["Coverage matrix", "Padding-box anatomy", "content 624 × 132", "Percentage inset", "Flex vs Grid", "Sizing modes", "Overflow clipping"],
  alert: ["Info", "Informational message.", "Success", "It worked.", "Warning", "Be careful.", "Error", "Something broke.", "Title-less alert with just a message."],
  notification: ["九种类型 Nine kinds", "成功 Success", "撤销 Undo", "堆叠 Stack", "连发 4 条", "八个停靠位置 Positions", "上左", "左中"],
  progress: ["25", "60", "100", "Heights", "Error", "indeterminate"],
  spinner: [], // 纯图形无文本 — 仅验面板挂载 + 截图
  skeleton: [], // 纯占位图形无文本
  timeline: ["Created", "Order placed", "09:00", "Shipped", "In transit", "Delivered", "Pending"],
  breadcrumb: ["Home", "Library", "Data"],
  steps: ["Horizontal", "Account", "Create account", "Profile", "Fill details", "Done", "Finish", "Vertical"],
  rate: ["value 3 / 5", "readonly value 4", "count 10, value 7", "Sizes"],
  tabs: ["underline", "pill", "tab", "Overview", "Details", "Settings", "Disabled", "Sizes", "One", "Two", "Three"],
  accordion: ["Section One", "Section Two", "Section Three", "Panel body content."],
  tree: ["src", "main.zig", "root.zig", "README.md"],
  table: ["Name", "Role", "Age", "Alice", "Admin", "Bob", "Carol", "Dave", "Editor", "Heidi", "41"],
  datatable: ["Name", "Role", "City", "Alice", "Berlin", "Carol", "Page 1 / 3", "Prev", "Next"],
  stepper: ["0–10, step 1", "5", "step 0.25", "0.50", "Disabled", "3"],
  tags: ["zig", "metal", "End with comma (or click Add) to commit a tag."],
  upload: ["Click Browse to add files", "Browse…"],
  menu: ["Click the trigger", "Actions"], // item 在闭合 popover 里，下方 interaction 测开后验
  dropdown: ["Click the trigger", "File"], // 同上
  tooltip: ["Hover a button", "Top", "Bottom", "Left", "Right"],
  popover: ["Click the button", "Toggle Popover", "Positions", "Hover me"],
  modal: ["Open Modal"],
  zindex: ["Sibling z-index", "Overflow container", "Pop", "Tip", "Open Nested Modal"],
  sheet: ["Open Sheet"],
  calendar: ["2026", "31"],
  datepicker: ["Pick a date"],
  daterange: ["Start date", "End date"],
  markdown: ["Markdown", "bold", "italic", "bullet one", "bullet two"],
  virtuallist: ["Row 0", "Row 1"],
  virtuallistdynamic: ["#0", "#1"],
  scrollarea: ["Scrollable line 0", "Scrollable line 1"],
  grid: ["0,0", "0,1", "1,0"],
  form: ["Name", "Email", "Submit", "Full name"],
  formcompose: ["Filter toolbar · same size", "Search orders…", "Status", "Owner", "Reset", "Apply filters", "New order", "Region", "Normal", "USD", "Create order"],
  wall: ["Actions", "Deploy", "Search components…", "Asia Pacific", "Sync over iCloud", "September 2026", "Aurora", "Build succeeded", "select.zig", "What is a retained tree?"],
  cleanup: ["Toggle child", "cleanups: 0", "cleanup child mounted"],
  // 只断言 provider-neutral system icon 契约；Storybook 不依赖具体供应商命名。
  icons: ["System icon contract", "activity", "check", "heart", "calendar", "Sizes & tints"],
  vectorpath: ["Batched fill_path", "polygon mode", "Bursts 40-pt", "triangles mode"],
  blend: ["Blend modes", "multiply", "screen", "difference", "normal control"],
  emoji: ["Color emoji", "red square", "green square", "blue square", "grayscale control", "mixed run"],
  rtl: [
    "RTL bidi text",
    "numbers + RTL",
    "mirrored punctuation",
    "Arabic tashkeel",
    "URL / email",
    "wrapped editable RTL",
  ],
  wordnav: ["Mixed-script sample", "привет", "αβγ", "Expected Alt+Right stops"],
  heavytext: ["Heavy text overflow", "glyph00"],
  textanimjitter: ["Rotate 360", "Opacity: fading in and out, steadily"],
  secsvg: ["Malformed SVG corpus", "close operand — rejected safely", "non-finite arc — rejected safely", "valid control rendered"],
  secopacity: ["10 nested composited opacity groups", "DEPTH 10 VISIBLE", "AFTER STACK MUST BE VISIBLE"],
  sectext: ["65,536-space editable run", "bytes: 65546", "Select all and replace with x"],
  teardownstress: ["Reactive teardown ordering", "grid mounted", "Run 10 cycles"],
};

const KEYS = Object.keys(EXPECT);

// 递归收集子树所有 text 字段。
function collectText(node: any, out: string[]): void {
  // display:none 子树（harness 标 hidden）不呈现，其中文字不算"可见文本"。
  if (node?.hidden) return;
  if (node?.text) out.push(node.text);
  for (const c of node?.children ?? []) collectText(c, out);
}

/// 在子树里按文本找节点，返回其 rect。
///
/// 组件内部大多没有 per-item test_id（Tabs/Accordion 的每个条目都是），
/// 而按坐标硬编码点击既脆弱又看不出意图。按 label 文本定位是这类
/// "点第 N 个条目" 交互的稳定写法。
function findByText(node: any, text: string): { x: number; y: number; w: number; h: number } | null {
  if (node?.text === text && node.rect) return node.rect;
  for (const c of node?.children ?? []) {
    const hit = findByText(c, text);
    if (hit) return hit;
  }
  return null;
}

async function clickText(rootTestId: string, text: string): Promise<void> {
  const root = (await query(rootTestId))[0];
  assert(root != null, `${rootTestId} 节点不存在`);
  const r = findByText(root, text);
  assert(r != null, `${rootTestId} 子树里找不到文本 "${text}"`);
  await clickAt(r!.x + r!.w / 2, r!.y + r!.h / 2);
}

/// EXPECT 为空且**是动画**的组件：单帧墨量判据不适用（截图时机决定图形转到
/// 哪个角度，墨量随之波动 —— spinner 实测 165~1032）。改验「它真的在动」：
/// 隔一小段时间截两帧，区域像素必须有差异。
///
/// 这同时比单帧墨量更贴近该组件的核心价值 —— spinner 的意义就是转。
const ANIMATED_INK = new Map<string, string>([["spinner", "story.spinner.row"]]);

async function assertAnimates(key: string, targetId: string): Promise<void> {
  const box = (await query(targetId))[0];
  assert(box != null, `${targetId} 节点不存在，无法做动画断言`);

  const pathA = `${DIR}/story-${key}-frameA.png`;
  const pathB = `${DIR}/story-${key}-frameB.png`;
  await screenshot(pathA);
  await sleep(180); // 足够 spinner 转过可见角度，又不拖慢整套
  await screenshot(pathB);

  const a = decodePng(pathA);
  const b = decodePng(pathB);
  const scale = a.width / 1100;
  const x0 = Math.max(0, Math.round(box.rect.x * scale));
  const y0 = Math.max(0, Math.round(box.rect.y * scale));
  const x1 = Math.min(a.width, Math.round((box.rect.x + box.rect.w) * scale));
  const y1 = Math.min(a.height, Math.round((box.rect.y + box.rect.h) * scale));
  let diff = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * a.width + x) * a.channels;
      if (Math.abs(a.pixels[i] - b.pixels[i]) > 6) diff++;
    }
  }
  appendLog(`  ${targetId}: 跨帧差异像素=${diff}`);
  assert(diff >= 50, `${targetId} 两帧之间没有变化（diff=${diff}）— 动画没在跑或图形没画出来`);
}

async function storyTexts(key: string): Promise<string> {
  const q = await query(`story.${key}`);
  const out: string[] = [];
  if (q[0]) collectText(q[0], out);
  return out.join(" │ ");
}

async function shot(name: string): Promise<number> {
  const path = `${DIR}/story-${name}.png`;
  const r = await screenshot(path);
  assert(r.ok === true, `screenshot rpc not ok for ${name}: ${JSON.stringify(r)}`);
  const size = statSync(path).size;
  appendLog(`  screenshot ${name}: ${size} bytes`);
  return size;
}

async function switchTo(storyKey: string): Promise<void> {
  // A failed overlay assertion must not poison every following test. Move the
  // pointer outside the window (fresh hover edge) and unwind up to three nested
  // overlay tiers before clicking the sidebar. Each RPC is processed on its
  // own app frame, so close effects commit between Escape presses.
  await mouseMove(-10, -10);
  for (let i = 0; i < 3; i++) await key("escape");
  const click = await clickTestId(`nav.${storyKey}`);
  assert(click.ok === true, `failed to click nav.${storyKey}: ${JSON.stringify(click)}`);
  // 等面板出现 **且** 文本子树已构建（Show 先挂 panel 容器再 build body，两步间
  // query 会看到空面板）。等到至少出现标题文本才算 ready，避免撞在 mount 中途。
  const panel = await waitFor(async () => {
    const q = await query(`story.${storyKey}`);
    if (q.length !== 1 || !q[0]) return null;
    const out: string[] = [];
    collectText(q[0], out);
    return out.length > 0 ? q : null;
  }, getE2eTimeoutMs(6000), 50);
  assert(panel.length === 1, `expected exactly 1 story.${storyKey} panel with content, got ${panel.length}`);
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
}, { fatal: true });

// ── 全组件：切换 + 数据值验证 + 截图（视觉 + log 数据值双重）──
for (const key of KEYS) {
  test(`${key}: 数据值 + 截图`, async () => {
    await switchTo(key);
    // log 数据值验证：预期值必须全部出现在 story 子树文本里。
    // 带重试：面板两段式挂载（先挂容器再 build body）下，单次 query 可能撞上
    // 重建瞬间拿到空子树（card/checkbox 偶发 flake 的根源）；数据真缺依然超时失败。
    let texts = "";
    await waitFor(async () => {
      texts = await storyTexts(key);
      const missing = EXPECT[key].filter((v) => !texts.includes(v));
      return missing.length === 0 ? true : null;
    }, getE2eTimeoutMs(5000), 60).catch(() => {});
    appendLog(`  story.${key} texts: ${texts || "(none)"}`);
    const missing = EXPECT[key].filter((v) => !texts.includes(v));
    assert(
      missing.length === 0,
      `story.${key} 缺数据值: [${missing.join(", ")}] — 实际文本: ${texts}`,
    );

    const path = `${DIR}/story-${key}.png`;
    await shot(key);

    // ⚠ 这里**不能**只断截图字节数。截图是整窗（含 41 项侧栏），实测任何存活
    // 状态下都是 22 万~36 万字节，而旧门槛写的是 3000 —— 低两个数量级，只有
    // app 整个死掉才可能触发，而那会被下面的 health() 先抓到。
    //
    // 对 EXPECT 为空的纯图形组件（spinner / skeleton），数据值断言也是空的，
    // 于是整条用例退化成「面板挂上了 + app 没死」—— 恰恰是最需要验像素的
    // 组件反而零视觉验证。改用 story 区域的墨量断言。
    // ⚠ 框选区域必须是图形**本身**，不能用 story.<key> —— 后者的 rect 还包含
    // 标题和描述文字，实测那些文字贡献 7600+ 深色像素，把「图形一个都没画出来」
    // 完全盖住（变异验证时 spinner 全部 size=0 仍然全绿）。
    // ⚠ spinner 刻意不在此列：它是旋转动画，截图时机决定圆弧转到哪个角度，
    //    与背景的对比像素量随之波动。实测孤立跑 634~1032，全量跑（已转两分钟）
    //    低至 165 —— 任何固定阈值要么假红要么形同虚设。旋转动画的正确验法是
    //    跨帧比较（两帧之间图形应当变化），不是单帧墨量，另案。
    //    skeleton 是静态图形，墨量稳定（实测 12 万+），适用。
    const INK_TARGET: Record<string, string> = {
      skeleton: "story.skeleton.col",
    };
    if (EXPECT[key].length === 0) {
      // 动画组件走跨帧判据（见 ANIMATED_INK 注释）
      if (ANIMATED_INK.has(key)) {
        await assertAnimates(key, ANIMATED_INK.get(key)!);
        return;
      }
      const targetId = INK_TARGET[key];
      assert(
        targetId != null,
        `${key} 的 EXPECT 为空但没有配 INK_TARGET —— 该用例会退化成零视觉验证。` +
          `若该组件是动画（像 spinner），单帧墨量判据不适用，需要跨帧比较，` +
          `请显式在这里说明并补对应用例。`,
      );
      const box = (await query(targetId))[0];
      assert(box != null, `${targetId} 节点不存在，无法做墨量断言`);
      assertRegionNotBlank(path, box.rect, targetId);
    }

    // app 仍存活（渲染/交互未崩）
    assert((await health()).status === "ok", `app died after ${key}`);
  });
}

// ── Layout / Box Model：几何真值验证 ──
// Story 本身负责可视化；这里直接读取同一批 test_id 的全局 rect，消掉父级
// 平移后断言局部 CSS 几何。这样 padding/content 坐标系再次混用时截图门和
// 数值门会同时变红。
test("LayoutBox: padding-box / percent / stretch / Flex / Grid geometry", async () => {
  await switchTo("layoutbox");

  const rect = async (id: string) => {
    const node = (await query(id))[0];
    assert(node != null && node.rect.w > 0 && node.rect.h > 0, `${id} 没有有效布局 rect`);
    return node.rect;
  };
  const near = (actual: number, expected: number, label: string, tolerance = 0.75) => {
    const delta = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(3)} expected=${expected.toFixed(3)} delta=${delta.toFixed(3)}`);
    assert(delta <= tolerance, `${label}: ${actual} != ${expected} (±${tolerance})`);
  };

  const parent = await rect("story.layoutbox.absolute.parent");
  const guide = await rect("story.layoutbox.absolute.content-guide");
  const origin = await rect("story.layoutbox.absolute.origin");
  const outer = await rect("story.layoutbox.absolute.outer-edge");
  const contentEdge = await rect("story.layoutbox.absolute.content-edge");
  near(guide.x - parent.x, 32, "content guide x");
  near(guide.y - parent.y, 28, "content guide y");
  near(guide.w, 624, "content guide width");
  near(guide.h, 132, "content guide height");
  near(origin.x - parent.x, 0, "left:0 origin x");
  near(origin.y - parent.y, 0, "top:0 origin y");
  near(parent.x + parent.w - (outer.x + outer.w), 0, "right:0 gap");
  near(parent.y + parent.h - (outer.y + outer.h), 0, "bottom:0 gap");
  near(parent.x + parent.w - (contentEdge.x + contentEdge.w), 44, "content-edge right gap");
  near(parent.y + parent.h - (contentEdge.y + contentEdge.h), 20, "content-edge bottom gap");

  const percentParent = await rect("story.layoutbox.percent.parent");
  const percent = await rect("story.layoutbox.percent.marker");
  near(percent.x - percentParent.x, 85.5, "left:25%");
  near(percent.y - percentParent.y, 75, "top:50%");

  const stretchParent = await rect("story.layoutbox.stretch.parent");
  const stretch = await rect("story.layoutbox.stretch.child");
  near(stretch.x - stretchParent.x, 14, "stretch left");
  near(stretch.y - stretchParent.y, 18, "stretch top");
  near(stretch.w, 306, "stretch width");
  near(stretch.h, 120, "stretch height");

  const flexParent = await rect("story.layoutbox.flex.parent");
  const flexA = await rect("story.layoutbox.flex.a");
  const flexB = await rect("story.layoutbox.flex.b");
  const flexAbs = await rect("story.layoutbox.flex.absolute");
  near(flexA.x - flexParent.x, 20, "Flex first item starts at padding.left");
  near(flexB.x - flexParent.x, 104, "Flex gap + B margin-left");
  near(flexAbs.x - flexParent.x, 308, "Flex absolute right:0 x");
  near(flexAbs.y - flexParent.y, 0, "Flex absolute top:0 y");

  const gridParent = await rect("story.layoutbox.grid.parent");
  const gridA = await rect("story.layoutbox.grid.a");
  const gridB = await rect("story.layoutbox.grid.b");
  const gridC = await rect("story.layoutbox.grid.c");
  const gridAbs = await rect("story.layoutbox.grid.absolute");
  near(gridA.x - gridParent.x, 20, "Grid first track x");
  near(gridA.w, 70, "Grid 70px track");
  near(gridB.x - gridParent.x, 98, "Grid 1fr track x");
  near(gridB.w, 72, "Grid 1fr width");
  near(gridC.x - gridParent.x, 178, "Grid 2fr track x");
  near(gridC.w, 144, "Grid 2fr width");
  near(gridAbs.x - gridParent.x, 308, "Grid absolute right:0 x");
  near(gridAbs.y - gridParent.y, 136, "Grid absolute bottom:0 y");

  const sizingParent = await rect("story.layoutbox.sizing.parent");
  const sizingPx = await rect("story.layoutbox.sizing.px");
  const sizingPercent = await rect("story.layoutbox.sizing.percent");
  const sizingGrow = await rect("story.layoutbox.sizing.grow");
  near(sizingPx.w, 80, "px sizing");
  near(sizingPercent.w, 132, "20% of 660 content width");
  near(sizingParent.x + sizingParent.w - (sizingGrow.x + sizingGrow.w), 20, "grow ends at content edge");
});

// ── 交互验证：Checkbox 点击改 status 文本（数据值变化）──
// ── 交互验证：Tabs 切换 ──
//
// Tabs 的**唯一核心语义**就是点击切换。此前这个 story 只有 EXPECT 静态文本
// 断言（"Overview" / "Details" 等标签文字出现），而标签文字在任何选中状态下
// 都在画面上 —— 点击根本不切换、或切到错误的 tab，都全绿漏过。
// ── 交互验证：Switch 拨动 ──
//
// Switch 的核心语义就是拨动开关。此前 EXPECT 只有 "Off"/"On"/"Disabled"
// 三个**标签文字**，它们在任何状态下都在画面上 —— 拨不动也全绿。
test("Steps: 连接线连贯（横向贯穿圆心 / 纵向末段贴圆圈）+ 圆圈序号居中", async () => {
  await switchTo("steps");
  await sleep(300);
  const panel = (await query("story.steps"))[0];
  const steppers: any[] = [];
  const walk = (n: any) => { if (n.component === "Steps") steppers.push(n); for (const c of n.children ?? []) walk(c); };
  walk(panel);
  assert(steppers.length === 2, `expected 2 Steps (horizontal + vertical), got ${steppers.length}`);
  const [h, v] = steppers;
  const cx = (r: any) => r.x + r.w / 2;
  const cy = (r: any) => r.y + r.h / 2;
  const near = (actual: number, expected: number, label: string, tol = 0.75) => {
    const d = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(2)} expected=${expected.toFixed(2)} delta=${d.toFixed(2)}`);
    assert(d <= tol, `${label}: ${actual} != ${expected} (±${tol})`);
  };

  // ── 横向：[track, progress, step0, step1, step2]，circle = step.children[0]
  const hk = h.children;
  const hCircles = hk.slice(2).map((s: any) => s.children[0].rect);
  const track = hk[0].rect, progress = hk[1].rect;
  assert(track.w > 0 && progress.w > 0, `横向连接线宽度为 0（track=${track.w} progress=${progress.w}）`);
  near(track.x, cx(hCircles[0]), "h track 起点 = 首圆心");
  near(track.x + track.w, cx(hCircles[hCircles.length - 1]), "h track 终点 = 末圆心");
  near(cy(track), cy(hCircles[0]), "h track 竖向居中于圆心");
  near(progress.x + progress.w, cx(hCircles[1]), "h progress 终点 = 当前(第 2 步)圆心");

  // ── 纵向：row → [indicator → [circle, connector?], text]
  const rows = v.children;
  for (let i = 0; i + 1 < rows.length; i++) {
    const c = rows[i].children[0].children[0].rect;
    const conn = rows[i].children[0].children[1].rect;
    const next = rows[i + 1].children[0].children[0].rect;
    near(conn.y, c.y + c.h, `v connector ${i} 顶 = 圆圈 ${i} 底`);
    near(conn.y + conn.h, next.y, `v connector ${i} 底 = 圆圈 ${i + 1} 顶`);
    near(cx(conn), cx(c), `v connector ${i} 水平居中`);
  }

  // ── 像素：线真的画出来、序号真的居中
  const path = `${DIR}/story-steps-connectors.png`;
  assert((await screenshot(path)).ok === true, "screenshot failed");
  const png = decodePng(path);
  const scale = png.width / 1100;
  const px = (x: number, y: number) => {
    const i = (Math.round(y * scale) * png.width + Math.round(x * scale)) * png.channels;
    return [png.pixels[i], png.pixels[i + 1], png.pixels[i + 2]];
  };
  const bg = px(h.rect.x + 2, h.rect.y + h.rect.h - 2);
  const differs = (p: number[]) => Math.abs(p[0] - bg[0]) + Math.abs(p[1] - bg[1]) + Math.abs(p[2] - bg[2]) > 30;
  for (let i = 0; i + 1 < hCircles.length; i++) {
    const midX = (hCircles[i].x + hCircles[i].w + hCircles[i + 1].x) / 2;
    const p = px(midX, cy(hCircles[0]));
    appendLog(`  h gap ${i} mid pixel=${p} bg=${bg}`);
    assert(differs(p), `横向第 ${i}→${i + 1} 段连接线没画出来（pixel=${p} ≈ bg=${bg}）`);
  }
  const lastConn = rows[rows.length - 2].children[0].children[1].rect;
  const lastCircle = rows[rows.length - 1].children[0].children[0].rect;
  for (let y = lastConn.y + 1; y < lastCircle.y + 2; y += 0.5) {
    const p = px(cx(lastConn), y);
    assert(differs(p), `纵向末段连接线在 y=${y.toFixed(1)} 断开（pixel=${p}，末圆圈顶 ${lastCircle.y}）`);
  }
  // 深色圆圈内白色序号墨迹质心 vs 圆心（内接正方形内统计，避开圆边抗锯齿）
  const inkCentroid = (r: any) => {
    const half = 9;
    let sx = 0, sy = 0, m = 0;
    for (let y = Math.round((cy(r) - half) * scale); y <= Math.round((cy(r) + half) * scale); y++) {
      for (let x = Math.round((cx(r) - half) * scale); x <= Math.round((cx(r) + half) * scale); x++) {
        const i = (y * png.width + x) * png.channels;
        const lum = 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
        const w = Math.max(0, lum - 128);
        sx += w * x; sy += w * y; m += w;
      }
    }
    assert(m > 0, "圆圈内没有白色序号墨迹");
    return [sx / m / scale, sy / m / scale];
  };
  for (const [label, r] of [["h 圆圈 2", hCircles[1]], ["v 末圆圈 3", lastCircle]] as const) {
    const [ix, iy] = inkCentroid(r);
    near(ix, cx(r), `${label} 序号墨迹 x`, 1.5);
    near(iy, cy(r), `${label} 序号墨迹 y`, 1.5);
  }
});

test("Switch: 交互 — 拨动改状态，disabled 不响应", async () => {
  await switchTo("switch");

  const statusOf = async () => (await query("story.switch.status"))[0]?.text ?? "";
  assert(
    (await statusOf()) === "toggled → (none)",
    `switch 初始 status 应为 "toggled → (none)"，got "${await statusOf()}"`,
  );

  // story.switch.off 的 initial_checked = false，拨一下必须变 on
  const sw = await screenPos("story.switch.off");
  await clickAt(sw.x + sw.h / 2, sw.y + sw.h / 2);
  await waitFor(async () => ((await statusOf()) !== "toggled → (none)" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "toggled → on",
    `拨动后应为 "toggled → on"（initial_checked=false），got "${await statusOf()}"`,
  );

  // 再拨一次回到 off —— 验证是真开关而不是单向置位
  await clickAt(sw.x + sw.h / 2, sw.y + sw.h / 2);
  await waitFor(async () => ((await statusOf()) === "toggled → off" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "toggled → off",
    `再拨一次应回到 "toggled → off"，got "${await statusOf()}"`,
  );
  await shot("switch-toggled-back");
});

// ── 交互验证：RadioGroup 互斥选择 ──
//
// 互斥是 radio 的**定义性语义**：选中 Y 必须让 X 失去选中。此前 EXPECT 只有
// "Option X/Y/Z" 三个标签文字，选不动、或三个同时选中，都全绿。
test("RadioGroup: 交互 — 选中切换且互斥", async () => {
  await switchTo("radio");

  const statusOf = async () => (await query("story.radio.status"))[0]?.text ?? "";
  assert(
    (await statusOf()) === "selected → (none)",
    `radio 初始 status 应为 "selected → (none)"，got "${await statusOf()}"`,
  );

  // 选 Option Y
  await clickText("story.radio.group", "Option Y");
  await waitFor(async () => ((await statusOf()) === "selected → y" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "selected → y",
    `点 Option Y 后应为 "selected → y"，got "${await statusOf()}"`,
  );

  // 选 Option Z —— 验证能连续切换（互斥生效的必要条件）
  await clickText("story.radio.group", "Option Z");
  await waitFor(async () => ((await statusOf()) === "selected → z" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "selected → z",
    `点 Option Z 后应为 "selected → z"，got "${await statusOf()}"`,
  );
  await shot("radio-selected-z");
});

// ── 交互验证：Accordion 展开/折叠 ──
//
// 此前只有 EXPECT 静态文本断言（"Section One" 等标题文字），而标题在展开
// 和折叠状态下都在画面上 —— 点击完全不生效也全绿。
//
// ⚠ 判据不能用「body 文本出现次数」：折叠只是把容器设成 height:0 +
//   overflow_hidden，**节点仍在树里**，文本收集照样拿到 3 份（实测）。
//   真正的可观测量是 body 容器的 rect.h。
test("Accordion: 交互 — 折叠首节高度归零，展开第二节高度撑开", async () => {
  await switchTo("accordion");

  /// 每一节 content 容器的高度：展开 > 0，折叠 == 0。
  ///
  /// ⚠ 必须看 content 这一层，不能看 body 子节点 —— body 的 rect.h 是内容
  /// 高度，折叠时不变（裁剪发生在渲染阶段，不改 layout rect，实测三节都是
  /// 34.2）。accordion.content 是组件内部给这层加的 test_id。
  const bodyHeights = async (): Promise<number[]> => {
    const ns = await query("accordion.content");
    assert(ns.length === 3, `应查到 3 个 accordion.content，got ${ns.length}`);
    return ns.map((n: any) => n.rect.h);
  };

  const expandedCount = async () => (await bodyHeights()).filter((h) => h > 0).length;

  assert(
    (await expandedCount()) === 1,
    `accordion 初始应恰好 1 节展开（story 里只有首节 expanded），实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );

  // 折叠首节 → 展开数归零
  await clickText("story.accordion", "Section One");
  await waitFor(async () => ((await expandedCount()) === 0 ? true : null)).catch(() => {});
  assert(
    (await expandedCount()) === 0,
    `折叠 Section One 后应 0 节展开，实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );
  await shot("accordion-collapsed");

  // 展开第二节 → 回到 1（验证展开也真生效，不是只有折叠单向可用）
  await clickText("story.accordion", "Section Two");
  await waitFor(async () => ((await expandedCount()) === 1 ? true : null)).catch(() => {});
  assert(
    (await expandedCount()) === 1,
    `展开 Section Two 后应 1 节展开，实际高度分布 ${JSON.stringify(await bodyHeights())}`,
  );
  await shot("accordion-section2-expanded");
});

test("Tabs: 交互 — 点击切换 active，且 disabled 不响应", async () => {
  await switchTo("tabs");

  const statusOf = async () => (await query("story.tabs.status"))[0]?.text ?? "";
  assert(
    (await statusOf()) === "active → (none)",
    `tabs 初始 status 应为 "active → (none)"，got "${await statusOf()}"`,
  );

  // 点 Details（t2）
  await clickText("story.tabs.underline", "Details");
  await waitFor(async () => ((await statusOf()) !== "active → (none)" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "active → t2",
    `点 Details 后应为 "active → t2"，got "${await statusOf()}"`,
  );
  await shot("tabs-active-t2");

  // 点 Settings（t3）—— 验证能连续切换，而不是只有首次生效
  await clickText("story.tabs.underline", "Settings");
  await waitFor(async () => ((await statusOf()) === "active → t3" ? true : null)).catch(() => {});
  assert(
    (await statusOf()) === "active → t3",
    `点 Settings 后应为 "active → t3"，got "${await statusOf()}"`,
  );

  // disabled tab 不得响应：status 必须停在 t3
  await clickText("story.tabs.underline", "Disabled");
  await sleep(200);
  assert(
    (await statusOf()) === "active → t3",
    `disabled tab 不应触发 on_change，status 应停在 "active → t3"，got "${await statusOf()}"`,
  );
  await shot("tabs-disabled-noop");

  // ⚠ 只断 on_change 回调**不够**：setActive 里 `if (index == active_index) return`
  // 是去重守卫，active_index 坏掉（恒为 0）时每次点击的 index 都 != 0，守卫不拦、
  // 回调照常触发 —— 回调全对但视觉选中态是坏的。实测变异（active_index 不更新）
  // 在只有回调断言时完全绿。所以必须另外断言**用户看得见的**选中态。
  //
  // underline 变体的选中指示是一条 highlight box，靠 translate_x 定位到当前 tab。
  // 断言它确实移动到了 Settings 的 x 位置（而不是停在首个 tab）。
  const root = (await query("story.tabs.underline"))[0];
  assert(root != null, "story.tabs.underline 不存在");
  const rSettings = findByText(root, "Settings");
  assert(rSettings != null, "找不到 Settings 标签");

  const rOverview = findByText(root, "Overview");
  assert(rOverview != null, "找不到 Overview 标签");

  // tabs.highlight 是选中指示条，translate_x 指向当前 active tab（局部坐标）。
  // 与标签 rect（全局坐标）不同系，所以比的是「相对首个 tab 的位移」。
  const hlAtSettings = (await query("tabs.highlight"))[0];
  assert(hlAtSettings != null, "找不到 tabs.highlight 节点");
  // translate_x 为 0 时 query 可能省略该字段，归一成 0 以免诊断里出现 undefined。
  const hlShift = hlAtSettings.translate_x ?? 0;
  const expectedShift = rSettings!.x - rOverview!.x;
  appendLog(
    `  tabs highlight: translate_x=${hlShift} 期望位移≈${expectedShift.toFixed(1)}`,
  );
  assert(
    Math.abs(hlShift - expectedShift) <= 6,
    `highlight 条未移到 Settings（translate_x=${hlShift}，期望≈${expectedShift.toFixed(1)}）` +
      ` —— active_index 没有驱动渲染`,
  );
});

test("Checkbox: 交互 — 点击改 status 值", async () => {
  await switchTo("checkbox");
  // switchTo 只等"面板出现任意文本"，status 节点的文本可能晚一拍 —— 显式等它就位
  // （偶发 flake："初始 status 应含 (none), got ''"）。
  const before = await waitFor(async () => {
    const t = (await query("story.checkbox.status"))[0]?.text ?? "";
    return t.length > 0 ? t : null;
  }, 4000, 50);
  appendLog(`  checkbox status before: "${before}"`);
  assert(before.includes("(none)"), `checkbox 初始 status 应含 (none), got "${before}"`);

  const pos = await screenPos("story.checkbox.box");
  await clickAt(pos.x + pos.h / 2, pos.y + pos.h / 2);
  await sleep(250);

  const after = (await query("story.checkbox.status"))[0]?.text ?? "";
  appendLog(`  checkbox status after: "${after}"`);
  await shot("checkbox-after-click");
  // ⚠ 不能写 `after.includes("checked")` —— "unchecked".includes("checked")
  // 为真，那样写分辨不出勾选和取消勾选，状态机反向的 bug 会全绿漏过。
  // story.checkbox.box 的 initial_checked = false，所以点一下必须是 checked。
  assert(
    after === "changed → checked",
    `checkbox 点击后 status 应为 "changed → checked"（initial_checked=false），got "${after}"`,
  );
});

// ── 交互验证：Slider 点 track，截图证明 thumb/值移动 ──
test("Slider: 交互 — 点 track 改值", async () => {
  await switchTo("slider");
  const pos = await screenPos("story.slider.track");
  appendLog(`  slider track: x=${pos.x} y=${pos.y} w=${pos.w}`);
  await clickAt(pos.x + pos.w * 0.8, pos.y + pos.h / 2);
  await sleep(250);
  // 点 80% 后第一个 slider 值应升到 ~80
  const texts = await storyTexts("slider");
  appendLog(`  slider texts after click: ${texts}`);
  await shot("slider-after-click");
  assert((await health()).status === "ok", "app died after slider interaction");
});

// ── 交互验证：Drag primitive — 拖动改状态/几何、click 抑制、Escape 取消回滚 ──
// 语义断言为主（docs/DRAG_INTERACTION_DESIGN.md §18.4），截图只作视觉辅助。
test("Slider: stepped drag stays snapped and ends on release", async () => {
  await switchTo("button");
  await switchTo("slider");
  const pos = await screenPos("story.slider.stepped.track");
  const y = pos.y + pos.h / 2;
  const expectValue = async (value: string) => {
    await waitFor(async () => {
      const nodes = await query("story.slider.stepped");
      return findRectByText(nodes[0], value);
    }, getE2eTimeoutMs(2000), 40).catch(async () => {
      throw new Error(`expected slider ${value}; state=${JSON.stringify(await query("story.slider.stepped"))}`);
    });
  };
  assert((await mouseDown(pos.x + pos.w * 0.5, y)).ok === true);
  try {
    await expectValue("5.0");
    assert((await mouseMove(pos.x + pos.w * 0.61, y)).ok === true);
    await expectValue("6.0");
    assert((await mouseMove(pos.x + pos.w * 0.64, y)).ok === true);
    await expectValue("6.0");
    assert((await mouseMove(pos.x + pos.w * 0.9, y)).ok === true);
    await expectValue("9.0");
  } finally {
    assert((await mouseUp(pos.x + pos.w * 0.9, y)).ok === true);
  }
  assert((await mouseMove(pos.x + pos.w * 0.1, y)).ok === true);
  await expectValue("9.0");
  await shot("slider-stepped-drag");
});

test("Slider: feedback playground is opt-in and can be reset and disabled", async () => {
  // Re-selecting the active story preserves state; remount before checking
  // the default-off contract independently of the preceding drag test.
  await switchTo("button");
  await switchTo("slider");
  const status = async () => (await query("story.slider.feedback.status"))[0]?.text ?? "";
  const expectStatus = async (text: string) => {
    await waitFor(async () => (await status()) === text ? true : null, getE2eTimeoutMs(2000), 40)
      .catch(async () => { throw new Error(`expected ${text}; got ${await status()}`); });
  };
  await expectStatus("Feedback: off | stepped: 5.0 | continuous: 5.0");
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  await expectStatus("Feedback: on | stepped: 5.0 | continuous: 5.0");
  const basic = await screenPos("story.slider.track");
  const basicY = basic.y + basic.h / 2;
  assert((await mouseDown(basic.x + basic.w * 0.4, basicY)).ok === true);
  try {
    assert((await mouseMove(basic.x + basic.w * 0.8, basicY)).ok === true);
    await waitFor(async () => findRectByText((await query("story.slider.basic"))[0], "80.0"), getE2eTimeoutMs(2000), 40);
  } finally {
    assert((await mouseUp(basic.x + basic.w * 0.8, basicY)).ok === true);
  }
  const stepped = await screenPos("story.slider.stepped.track");
  const y = stepped.y + stepped.h / 2;
  assert((await mouseDown(stepped.x + stepped.w * 0.5, y)).ok === true);
  try {
    assert((await mouseMove(stepped.x + stepped.w * 0.81, y)).ok === true);
    await expectStatus("Feedback: on | stepped: 8.0 | continuous: 5.0");
  } finally {
    await mouseUp(stepped.x + stepped.w * 0.81, y);
  }
  const continuous = await screenPos("story.slider.continuous.track");
  assert((await clickAt(continuous.x + continuous.w * 0.63, continuous.y + continuous.h / 2)).ok === true);
  await expectStatus("Feedback: on | stepped: 8.0 | continuous: 6.3");
  await shot("slider-feedback-on");
  assert((await clickTestId("story.slider.feedback.reset")).ok === true);
  await expectStatus("Feedback: on | stepped: 5.0 | continuous: 5.0");
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  await expectStatus("Feedback: off | stepped: 5.0 | continuous: 5.0");
  assert((await clickAt(stepped.x + stepped.w * 0.7, y)).ok === true);
  await expectStatus("Feedback: off | stepped: 7.0 | continuous: 5.0");
  await shot("slider-feedback-off");
});

test("Slider: native patterns are selectable without implicitly enabling feedback", async () => {
  await switchTo("button");
  await switchTo("slider");
  const expectPattern = async (name: string) => {
    await waitFor(async () => (await query("story.slider.feedback.pattern"))[0]?.text === `Pattern: ${name}` ? true : null,
      getE2eTimeoutMs(2000), 40);
  };
  const expectEnabled = async (enabled: boolean) => {
    const text = (await query("story.slider.feedback.status"))[0]?.text ?? "";
    assert(text.startsWith(`Feedback: ${enabled ? "on" : "off"} |`), `wrong feedback state: ${text}`);
  };
  await expectPattern("Alignment");
  assert((await clickTestId("story.slider.pattern.generic")).ok === true);
  await expectPattern("Generic");
  await expectEnabled(false);
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  for (const [id, name, ratio, value] of [
    ["generic", "Generic", 0.7, "7.0"],
    ["level_change", "Level change", 0.3, "3.0"],
    ["alignment", "Alignment", 0.6, "6.0"],
  ] as const) {
    assert((await clickTestId(`story.slider.pattern.${id}`)).ok === true);
    await expectPattern(name);
    await expectEnabled(true);
    const track = await screenPos("story.slider.stepped.track");
    assert((await clickAt(track.x + track.w * ratio, track.y + track.h / 2)).ok === true);
    await waitFor(async () => findRectByText((await query("story.slider.stepped"))[0], value), getE2eTimeoutMs(2000), 40);
  }
  assert((await clickTestId("story.slider.feedback.toggle")).ok === true);
  assert((await clickTestId("story.slider.pattern.level_change")).ok === true);
  await expectPattern("Level change");
  await expectEnabled(false);
  await shot("slider-pattern-settings");
});

test("Drag: 交互 — 拖动方块 + click 抑制 + Escape 取消", async () => {
  await switchTo("drag");
  const box = await screenPos("story.drag.box");
  const cx0 = box.x + box.w / 2;
  const cy0 = box.y + box.h / 2;

  // 1) 拖 60px：status → end，click 被抑制（clicks 保持 0）
  await mouseDown(cx0, cy0);
  await mouseMove(cx0 + 30, cy0 + 10);
  await mouseMove(cx0 + 60, cy0 + 20);
  await mouseUp(cx0 + 60, cy0 + 20);
  await sleep(250);
  let texts = await storyTexts("drag");
  appendLog(`  drag texts after drag: ${texts}`);
  assert(texts.includes("state: end"), `drag end 状态未出现: ${texts}`);
  assert(texts.includes("clicks: 0"), `drag 后 click 未被抑制: ${texts}`);
  // 方块真的按 delta 移动了（几何验证）
  const moved = await screenPos("story.drag.box");
  assert(Math.abs(moved.x - box.x - 60) <= 2, `box 未按 delta.x=60 移动: ${box.x} -> ${moved.x}`);

  // 2) 原地短点击（未越阈值）：click 保持有效，计数 +1
  await clickAt(moved.x + moved.w / 2, moved.y + moved.h / 2);
  await sleep(250);
  texts = await storyTexts("drag");
  assert(texts.includes("clicks: 1"), `普通 click 未恢复: ${texts}`);

  // 3) 拖动中 Escape：cancel 文案 + 位置回滚，后到的 up 不产生 click
  const p2 = await screenPos("story.drag.box");
  const cx2 = p2.x + p2.w / 2;
  const cy2 = p2.y + p2.h / 2;
  await mouseDown(cx2, cy2);
  await mouseMove(cx2 + 40, cy2);
  await key("escape");
  await mouseUp(cx2 + 40, cy2);
  await sleep(250);
  texts = await storyTexts("drag");
  appendLog(`  drag texts after escape: ${texts}`);
  assert(texts.includes("state: cancel (escape)"), `Escape 取消状态未出现: ${texts}`);
  assert(texts.includes("clicks: 1"), `取消后的 up 不应产生 click: ${texts}`);
  const back = await screenPos("story.drag.box");
  assert(Math.abs(back.x - p2.x) <= 2, `cancel 未回滚位置: ${p2.x} -> ${back.x}`);

  await shot("drag-after-interactions");
  assert((await health()).status === "ok", "app died after drag interaction");
});

// ── 交互验证：Modal 点按钮打开 → dialog 真正可见 + 居中 + body 文本出现 ──
// blend_mode 端到端像素验收（2026-07-30 接线）。颜色全用 0/255 分量 ——
// sRGB 传递函数在 0/1 处不变，线性/sRGB 空间的混合结果一致，可按精确值断言。
// 此前 blend_mode 两头都断（无 API 可设、encoder 不消费），multiply 等静默
// 退化成 normal —— 那种情况下 multiply 位置会读到 cyan 而不是 green，此测必红。
test("BlendModes: 像素 — multiply/screen/difference 精确色值 + normal 对照", async () => {
  await switchTo("blend");
  await sleep(400); // settle
  await shot("blend-modes");
  const png = `${DIR}/story-blend-modes.png`;

  const cases: Array<[string, [number, number, number]]> = [
    ["story.blend.multiply", [0, 255, 0]],     // yellow x cyan
    ["story.blend.screen", [255, 0, 255]],     // red + blue
    ["story.blend.difference", [0, 255, 255]], // |white - red|
    ["story.blend.control", [0, 255, 255]],    // normal 对照：保持 cyan
  ];
  for (const [id, expected] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    assertColorNear(centerPixel(png, nodes[0].rect), expected, id);
  }
});

// 回归：Modal 曾完全不可用 —— barrier 的 absolute grow/grow containing block 是它内联
// 所在的 844px content 面板（非窗口），打开后只有 844x32 错位条、dialog 不居中、body
// h=0。修法：window-root portal + content 走内联 scale_fade（非 composited surface，
// 后者把居中 dialog 的 GPU draw 画回 (0,0)）。此测点真实按钮、断言 dialog 居中可见。
test("Modal: 交互 — 打开后 dialog 居中可见 + body 文本", async () => {
  await switchTo("modal");
  await shot("modal-closed");
  // 点真实按钮（用 test_id，不靠手算坐标）
  const btn = await screenPos("story.modal.open");
  await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);
  await sleep(900); // 等入场动画settle
  await shot("modal-open");

  // dialog 必须真正布局出来（非 0x0）
  const dlg = (await query("story.modal.dialog"))[0];
  assert(dlg != null, "modal dialog 节点查不到（未打开？）");
  const r = dlg.rect;
  appendLog(`  modal dialog rect=(${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.w)}x${Math.round(r.h)})`);
  assert(r.w > 100 && r.h > 40, `modal dialog 尺寸异常 (${r.w}x${r.h}) — 应是真实 dialog`);

  // 居中：dialog 中心应靠近窗口水平中心（窗口宽 1100，中心 ~550）。
  // 旧 bug 下 dialog 会贴在面板左侧 (x~228)。
  const cx_dialog = r.x + r.w / 2;
  assert(cx_dialog > 400, `modal dialog 未水平居中 (center_x=${Math.round(cx_dialog)}, 应 > 400)`);

  // body 文本必须可见（h>0）。旧 bug 下 body h=0。
  const out: string[] = [];
  collectText(dlg, out);
  const joined = out.join(" │ ");
  appendLog(`  modal dialog texts: ${joined}`);
  assert(joined.includes("Example Modal"), `modal 缺标题 — 实际: ${joined}`);
  assert(joined.includes("Modal body content."), `modal 缺 body 文本 — 实际: ${joined}`);

  // 像素级：settled dialog 内必须真的画出了文字（回归门：settle 帧空白面板 bug）。
  assertRegionHasInk(`${DIR}/story-modal-open.png`, r, "modal dialog pixels");

  // 反向像素门（2026-07-30 回归教训）：dialog **左侧的 backdrop 区域必须无墨**。
  // GPU retained 的 miss 路径曾漏掉开层前的 pipeline flush，把整块页面内容
  // （含 Open Modal 按钮）冲进 overlay surface 纹理并缓存 —— 表现为 backdrop
  // 里出现重复的深色按钮/文字。该 bug 逃过了全部 51 项断言（只有"有墨"门，
  // 没有"无墨"门）。区域取 dialog 左侧一块纯 dim 区。
  {
    const png = decodePng(`${DIR}/story-modal-open.png`);
    const scale = png.width / 1100;
    const leftOfDialog = { x: 300, y: r.y, w: Math.max(60, r.x - 320), h: r.h };
    const stray = countDarkPixels(png, leftOfDialog, scale);
    appendLog(`  modal backdrop stray ink: dark_pixels=${stray} (max=50)`);
    assert(stray <= 50, `modal backdrop 出现不该有的内容（dark=${stray} > 50）— 疑似 surface 纹理被污染/错位合成`);
  }

  // 关键回归（hit-test）：点 dialog **内部空白/正文**绝不能关闭 modal。
  // 之前 barrier/content 无 pointer hit role → 点击穿透到背后 ScrollArea →
  // outside-click 误判"点在 content 外" → 任意点击都误关。dialog 节点跨开关复用、
  // 不销毁，故用 visible 字段判定开关（关闭后 query 仍返回该节点，但 visible=false）。
  const dcx = r.x + r.w / 2, dcy = r.y + r.h * 0.75; // dialog 下半部空白区
  await clickAt(dcx, dcy);
  await sleep(500);
  const afterInside = (await query("story.modal.dialog"))[0];
  appendLog(`  after inside-dialog click, visible=${afterInside?.visible}`);
  assert(afterInside?.visible !== false, `点 dialog 内部竟关闭了 modal（hit-test 穿透）`);

  // 点 × 关闭 —— 必须真正触发 × 的 handler（而非穿透触发 outside-dismiss）。
  await clickTestId("modal.close");
  await sleep(800);
  const closed = (await query("story.modal.dialog"))[0];
  appendLog(`  after × click, dialog visible=${closed?.visible}`);
  assert(closed?.visible === false, `× 关闭按钮没生效（dialog 仍 visible）`);
  assert((await health()).status === "ok", "app died after closing modal");
});

// ── 交互验证：Sheet 点按钮打开 → panel 贴右边可见 + content 文本 ──
/// 在截图的 y 行（逻辑坐标）从右往左找第一个非浅色像素 —— sheet 白面板
/// 左缘与灰 backdrop 的分界。返回逻辑 x；整行浅色返回 null。
function sheetPanelEdgeX(pngPath: string, logicalY: number): number | null {
  const png = decodePng(pngPath);
  const scale = png.width / 1100;
  const y = Math.round(logicalY * scale);
  for (let x = png.width - 1; x > png.width * 0.3; x--) {
    const i = (y * png.width + x) * png.channels;
    const lum = (png.pixels[i] + png.pixels[i + 1] + png.pixels[i + 2]) / 3;
    if (lum < 235) return (x + 1) / scale;
  }
  return null;
}

test("Sheet: 交互 — 打开后 panel 贴边可见 + content 文本", async () => {
  await switchTo("sheet");
  const btn = await screenPos("story.sheet.open");
  await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);

  // ── 动画中段像素门（2026-07-30 Sheet 冻结回归）────────────────────
  // GPU retained 的指纹曾漏掉嵌套 begin_opacity_layer 的合成参数：子层
  // transform 每帧在变而父层（window-root overlay group）指纹不变 → 父层
  // 帧帧 stale hit → 滑入动画像素全程冻结、结束瞬间跳到终点。布局树照常
  // 推进，所以 rect 断言全过 —— 只有**动画中段的像素**能逮住它。
  // settle 位置 x≈780；此处断言 t≈120ms 时面板左缘"已入场且未定格"。
  await sleep(120);
  await shot("sheet-mid-anim");
  const midEdge = sheetPanelEdgeX(`${DIR}/story-sheet-mid-anim.png`, 500);
  appendLog(`  sheet mid-anim panel edge x=${midEdge == null ? "none" : Math.round(midEdge)}`);
  assert(
    midEdge != null && midEdge > 788 && midEdge < 1098,
    `sheet 滑入动画中段面板位置异常 (edge=${midEdge == null ? "不可见" : Math.round(midEdge)}) — ` +
      `应在 (788,1098) 之间；=780 表示画面直接跳到终点（动画冻结），不可见表示还没入场`,
  );

  await sleep(780);
  await shot("sheet-open");

  const panel = (await query("story.sheet.panel"))[0];
  assert(panel != null, "sheet panel 节点查不到（未打开？）");
  const r = panel.rect;
  appendLog(`  sheet panel rect=(${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.w)}x${Math.round(r.h)})`);
  assert(r.w > 100 && r.h > 100, `sheet panel 尺寸异常 (${r.w}x${r.h})`);
  // side=right：panel 右缘应贴近窗口右缘（~1100）。
  assert(r.x + r.w > 900, `sheet panel 未贴右边 (right=${Math.round(r.x + r.w)})`);

  const out: string[] = [];
  collectText(panel, out);
  assert(out.join(" ").includes("Sheet panel content."), `sheet 缺 content 文本 — 实际: ${out.join(" ")}`);

  // 像素级：settled panel 内必须真的画出了文字（回归门：settle 帧空白面板 bug）。
  assertRegionHasInk(`${DIR}/story-sheet-open.png`, r, "sheet panel pixels");

  // 关键回归（hit-test）：点 panel 内部不能关闭；点左侧 backdrop 空白才关闭。
  // 顺带必须关掉 sheet —— sheet barrier 现在真的拦截点击（modal 语义），不关会挡住
  // 后续测试的 nav 切换。
  await clickAt(r.x + r.w / 2, r.y + r.h / 2); // panel 内部
  await sleep(400);
  const afterInside = (await query("story.sheet.panel"))[0];
  assert(afterInside?.visible !== false, `点 sheet panel 内部竟关闭了（hit-test 穿透）`);
  await clickAt(80, 500); // 左侧 backdrop（panel 在右侧）
  await sleep(600);
  const closed = (await query("story.sheet.panel"))[0];
  appendLog(`  after backdrop click, sheet panel visible=${closed?.visible}`);
  assert(closed?.visible === false, `sheet backdrop 点击未关闭`);
  assert((await health()).status === "ok", "app died after closing sheet");
});

// ── 交互验证：Menu 点 trigger 打开 → 弹层出现 item 数据值 ──
function findRectByText(node: any, label: string): any {
  if (node?.text === label) return node.rect ?? null;
  for (const c of node?.children ?? []) {
    const r = findRectByText(c, label);
    if (r) return r;
  }
  return null;
}

test("Notification: 九种类型、折叠 / 展开堆叠、悬停暂停、删除中间一条平滑补位、八个位置、原地转换", async () => {
  await switchTo("notification");

  // 提醒挂在 window-root portal；只收集**提醒卡片与角标**里的文字——宿主的
  // 历史行（面板关着时也在树上）会含同样的标题，查整棵树会把已退场的卡片误判为仍在。
  async function fullTreeTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification" || n.component === "Notification.pill") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function windowSize(): Promise<{ w: number; h: number }> {
    const full = await tree();
    return { w: full.rect.w, h: full.rect.h };
  }
  // 悬停判定按指针真实坐标逐帧命中测试（16.7）。窗口若正好弹在物理鼠标下，真实
  // 移动事件会覆盖注入坐标（实测抓到过 (427,748) 这类非注入坐标）——等待期间持续重发。
  async function holdPointer(x: number, y: number, ms: number): Promise<void> {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      await mouseMove(x, y);
      await sleep(Math.min(100, Math.max(0, end - Date.now())));
    }
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  const win = await windowSize();
  await clearAll();

  // 1. 成功卡：入场结束后贴 bottom-center 锚点（边距 22），悬停暂停计时。
  await clickTestId("story.notify.btn.success");
  await shot("notify-success-entering");
  await sleep(700);
  await shot("notify-success-settled");
  let joined = await fullTreeTexts();
  assert(joined.includes("已保存到 iCloud"), `success 缺文本 — ${joined}`);
  const success = await screenPos("story.notify.success");
  appendLog(`  success rect: ${JSON.stringify(success)} window ${JSON.stringify(win)}`);
  assert(Math.abs(success.w - 392) < 0.5, `卡片宽度应为 392: ${success.w}`);
  assert(Math.abs(success.x + success.w / 2 - win.w / 2) < 1, `bottom-center 未水平居中: ${success.x}`);
  assert(Math.abs(success.y + success.h - (win.h - 22)) < 1.5, `底部边距应为 22: bottom=${success.y + success.h}`);
  assertRegionHasInk(`${DIR}/story-notify-success-settled.png`, success, "success card pixels", 50);
  await holdPointer(success.x + 200, success.y + success.h / 2, 4200); // 已超过 3600ms 停留，悬停时必须仍在。
  await shot("notify-success-hover-paused");
  assert((await fullTreeTexts()).includes("已保存到 iCloud"), "悬停没有暂停计时");
  await mouseMove(-10, -10);
  await waitFor(async () => ((await fullTreeTexts()).includes("已保存到 iCloud") ? null : true), 5000, 100);
  await shot("notify-success-expired");

  // 2. 九种类型都能真实弹出（外观与稿子的逐像素比对另见 design_diff 流程）。
  for (const [kind, text] of [
    ["error", "network timeout"],
    ["warning", "磁盘空间不足"],
    ["progress", "正在上传附件"],
    ["action", "邀请你加入文档"],
    ["person", "林可可"],
    ["undo", "已移动 4 个项目到废纸篓"],
    ["quiet", "已切换到分支"],
    ["digest", "勿扰期间收到 7 条提醒"],
  ] as const) {
    await clearAll();
    await clickTestId(`story.notify.btn.${kind}`);
    await sleep(700);
    await shot(`notify-kind-${kind}`);
    assert((await fullTreeTexts()).includes(text), `${kind} 未出现: ${text}`);
  }
  await clearAll();

  // 3. 连发 4 条：折叠态后层只露 9px，最新那张在最前（最靠近锚点）。
  await clickTestId("story.notify.btn.burst");
  await sleep(800);
  await shot("notify-stack-collapsed");
  const c0 = await screenPos("story.notify.stack.3");
  const c1 = await screenPos("story.notify.stack.2");
  const c2 = await screenPos("story.notify.stack.1");
  appendLog(`  collapsed tops: ${c0.y} ${c1.y} ${c2.y}`);
  // 折叠态被裁到最前那张的高度：底边依次上移 9px。
  assert(Math.abs((c0.y + c0.h) - (c1.y + c1.h) - 9) < 1, `第 2 层露边应为 9px: ${(c0.y + c0.h) - (c1.y + c1.h)}`);
  assert(Math.abs((c1.y + c1.h) - (c2.y + c2.h) - 9) < 1, `第 3 层露边应为 9px`);
  joined = await fullTreeTexts();
  assert(joined.includes("还有 3 条 · 悬停展开"), `折叠角标文案不对 — ${joined}`);

  // 4. 悬停展开：按真实高度排列，间距 9；角标换成「悬停中」。
  await holdPointer(c0.x + 200, c0.y + c0.h / 2, 800);
  await shot("notify-stack-expanded");
  const e0 = await screenPos("story.notify.stack.3");
  const e1 = await screenPos("story.notify.stack.2");
  const e2 = await screenPos("story.notify.stack.1");
  const e3 = await screenPos("story.notify.stack.0");
  appendLog(`  expanded: ${JSON.stringify([e0, e1, e2, e3].map((r) => [r.y, r.h]))}`);
  assert(Math.abs(e0.y - (e1.y + e1.h) - 9) < 1, `展开间距应为 9: ${e0.y - (e1.y + e1.h)}`);
  assert(Math.abs(e1.y - (e2.y + e2.h) - 9) < 1, `展开间距应为 9`);
  assert(Math.abs(e2.y - (e3.y + e3.h) - 9) < 1, `展开间距应为 9`);
  assert((await fullTreeTexts()).includes("悬停中 · 全部计时已暂停"), "展开角标文案不对");

  // 5. 删除中间一条：下方补位连续（逐帧采样单调、无跳变），其余卡片不重建。
  const before = e3.y;
  await clickTestId("story.notify.stack.1.close");
  // 点击把指针留在了被删那张的 ✕ 上；补位后那里可能已在堆叠外，退场结束会按真实
  // 坐标复核并折叠（16.7 规范行为）。模拟用户继续悬停：指针回到最前那张（位置不变）。
  // 补位是 300ms 的 cubicBezier(0.22,0.92,0.24,1)：起步斜率 ≈4.2，头 60ms 就能走完
  // ~80% —— 用「单步 < 总距 70%」判跳变与曲线本身矛盾（首个采样点落在曲线哪里只
  // 取决于 RPC 延迟），曾是偶发失败的根因。平滑补位的真实语义是：能观察到介于起点
  // 与终点之间的中间位置（瞬移则一个都没有）、单调、终点正确。
  // 点击后立即采样（先采样再按住指针），首个样本尽量早。
  const target = before + e2.h + 9;
  const samples: number[] = [];
  for (let i = 0; i < 8; i++) {
    samples.push((await screenPos("story.notify.stack.0")).y);
    await holdPointer(e0.x + 200, e0.y + e0.h / 2, 40);
  }
  await shot("notify-stack-middle-removed");
  appendLog(`  reflow samples: before=${before} target=${target} ${samples.join(", ")}`);
  let prev = before;
  for (const y of samples) {
    assert(y >= prev - 0.5, `补位方向不对（应向下补）: ${prev} → ${y}`);
    prev = y;
  }
  const intermediate = samples.filter((y) => y > before + 1 && y < target - 1);
  assert(intermediate.length > 0, `补位没有过渡（瞬移）: ${samples.join(", ")}`);
  const settled = samples[samples.length - 1];
  assert(Math.abs(settled - target) < 2, `补位终点不对: ${settled} vs ${target}`);
  assert((await query("story.notify.stack.1")).length === 0, "被关闭的中间一条没有移除");
  assert((await query("story.notify.stack.3")).length === 1, "上方卡片被重建（test id 丢失）");
  await clearAll();

  // 6. 八个位置：锚点 + 符号。只断言有代表性的四个角与两侧中点。
  for (const [pos, check] of [
    ["tr", (r: any) => Math.abs(r.x + r.w - (win.w - 22)) < 1.5 && Math.abs(r.y - (56 + 22)) < 1.5],
    ["tl", (r: any) => Math.abs(r.x - 22) < 1.5 && Math.abs(r.y - (56 + 22)) < 1.5],
    ["bl", (r: any) => Math.abs(r.x - 22) < 1.5 && Math.abs(r.y + r.h - (win.h - 22)) < 1.5],
    ["rc", (r: any) => Math.abs(r.x + r.w - (win.w - 22)) < 1.5 && Math.abs(r.y + r.h / 2 - (56 + (win.h - 56) / 2)) < 1.5],
    ["lc", (r: any) => Math.abs(r.x - 22) < 1.5],
  ] as const) {
    await clickTestId(`story.notify.pos.${pos}`);
    await clickTestId("story.notify.btn.warning");
    await sleep(800);
    await shot(`notify-position-${pos}`);
    const r = await screenPos("story.notify.warning");
    appendLog(`  position ${pos}: ${JSON.stringify(r)}`);
    assert(check(r), `位置 ${pos} 几何不对: ${JSON.stringify(r)}`);
    await clearAll();
  }
  await clickTestId("story.notify.pos.bc");

  // 7. 原地转换：撤销 → 环换成 ✓；接受 → 按钮区移除、高度收缩。card 不重建（test id 保留）。
  await clickTestId("story.notify.btn.undo");
  await sleep(700);
  const undoBefore = await screenPos("story.notify.undo");
  await clickTestId("story.notify.undo.action.0");
  await sleep(500);
  await shot("notify-undo-settled");
  const status1: string[] = [];
  const st1 = await query("story.notify.status");
  if (st1[0]) collectText(st1[0], status1);
  assert(status1.join(" ").includes("undo"), `撤销事件未上报 — ${status1.join(" ")}`);
  const undoAfter = await screenPos("story.notify.undo");
  assert(undoAfter.h < undoBefore.h - 20, `撤销后按钮区应移除: ${undoBefore.h} → ${undoAfter.h}`);
  await clearAll();

  await clickTestId("story.notify.btn.action");
  await sleep(700);
  const acceptBefore = await screenPos("story.notify.action");
  await clickTestId("story.notify.action.action.0");
  await sleep(700);
  await shot("notify-accept-settled");
  const acceptAfter = await screenPos("story.notify.action");
  assert(acceptAfter.h < acceptBefore.h - 20, `接受后按钮区应移除: ${acceptBefore.h} → ${acceptAfter.h}`);
  assert((await fullTreeTexts()).includes("已加入文档"), "接受后标题未改写");
  await clearAll();
});

test("Notification: 拖拽关闭（84px 阈值 / 弹回 / 甩出）、不可拖拽区、内联回复 Enter 提交", async () => {
  await switchTo("notification");
  // 只查提醒卡片（宿主的通知中心历史行可能在树上有同样标题）。
  async function fullTreeTexts(): Promise<string> {
    const o: string[] = [];
    const walk = (n: any) => {
      if (n.component === "Notification") collectText(n, o);
      else for (const c of n.children ?? []) walk(c);
    };
    walk(await tree());
    return o.join(" │ ");
  }
  async function clearAll(): Promise<void> {
    await mouseMove(-10, -10);
    await clickTestId("story.notify.btn.clear");
    await sleep(600);
  }
  // 真实指针拖拽：分步移动，每步一帧。
  async function dragBy(x: number, y: number, dx: number): Promise<void> {
    await mouseDown(x, y);
    const steps = 8;
    for (let i = 1; i <= steps; i++) {
      await mouseMove(x + (dx * i) / steps, y);
      await sleep(16);
    }
    await mouseUp(x + dx, y);
  }
  await clearAll();

  // 1. dx = 40：未达阈值，松手弹回原位。
  await clickTestId("story.notify.btn.warning");
  await sleep(700);
  const w0 = await screenPos("story.notify.warning");
  await dragBy(w0.x + 120, w0.y + w0.h / 2, 40);
  await shot("notify-swipe-under-threshold-released");
  await sleep(700);
  const w1 = await screenPos("story.notify.warning");
  appendLog(`  swipe 40 → x ${w0.x} → ${w1.x}`);
  assert(Math.abs(w1.x - w0.x) < 1, `未达阈值应弹回: ${w0.x} → ${w1.x}`);
  assert((await fullTreeTexts()).includes("磁盘空间不足"), "未达阈值却被关闭");

  // 2. dx = 130：越过 84px，关闭并甩出。
  await dragBy(w0.x + 120, w0.y + w0.h / 2, 130);
  await sleep(60);
  await shot("notify-swipe-fling");
  await sleep(600);
  assert(!(await fullTreeTexts()).includes("磁盘空间不足"), "越过阈值没有关闭");
  await clearAll();

  // 3. 在按钮区按下拖动不开始滑动手势（data-noswipe）。
  await clickTestId("story.notify.btn.error");
  await sleep(700);
  const retry = await screenPos("story.notify.error.action.1");
  const e0 = await screenPos("story.notify.error");
  await dragBy(retry.x + retry.w / 2, retry.y + retry.h / 2, 140);
  await sleep(600);
  const e1 = await screenPos("story.notify.error");
  assert(Math.abs(e1.x - e0.x) < 1 && (await fullTreeTexts()).includes("上传失败"), `按钮区拖动触发了手势: ${e0.x} → ${e1.x}`);
  await clearAll();

  // 4. 内联回复：输入 + Enter → 原地换成引用，卡片不重建，事件带回复内容。
  await clickTestId("story.notify.btn.person");
  await sleep(700);
  const p0 = await screenPos("story.notify.person");
  // 回复框在分隔线下方：卡片底部往上 ~25px。
  await clickAt(p0.x + 120, p0.y + p0.h - 25);
  await type_("好的，马上看");
  await sleep(150);
  await shot("notify-reply-typed");
  await key("return");
  await sleep(500);
  await shot("notify-reply-sent");
  // 文本断言读的是节点树、不管画没画出来；原地转换后必须真有像素（实测回归：
  // 悬停暂停时新内容层整块不显示）。
  const sent = await screenPos("story.notify.person");
  assertRegionHasInk(`${DIR}/story-notify-reply-sent.png`, { x: sent.x + 60, y: sent.y + 10, w: 260, h: sent.h - 20 }, "reply sent content pixels", 150);
  const joined = await fullTreeTexts();
  assert(joined.includes("好的，马上看"), `回复内容未以引用出现 — ${joined}`);
  const st: string[] = [];
  const sq = await query("story.notify.status");
  if (sq[0]) collectText(sq[0], st);
  assert(st.join(" ").includes("reply"), `回复事件未上报 — ${st.join(" ")}`);
  assert((await query("story.notify.person")).length === 1, "发送后卡片被重建（test id 丢失）");
  await clearAll();
});

test("NumberStepper: 交互 — 点 + 步进", async () => {
  await switchTo("stepper");
  const tree = await query("story.stepper.basic");
  const plus = findRectByText(tree[0], "+");
  assert(plus, "找不到 + 按钮");
  await clickAt(plus.x + plus.w / 2, plus.y + plus.h / 2);
  await sleep(250);
  const t1 = await query("story.stepper.basic");
  const out: string[] = [];
  if (t1[0]) collectText(t1[0], out);
  appendLog(`  stepper after +: ${out.join(" │ ")}`);
  assert(out.includes("6"), `+ 后应为 6 — ${out.join(" │ ")}`);
  // Cross the digit boundary through real clicks: text content alone would
  // miss a stale intrinsic-width cache that clips the newly rendered label.
  let nine: any;
  for (let value = 7; value <= 10; value++) {
    assert((await clickAt(plus.x + plus.w / 2, plus.y + plus.h / 2)).ok === true);
    const rect = await waitFor(async () => {
      const current = await query("story.stepper.basic");
      return findRectByText(current[0], String(value));
    }, getE2eTimeoutMs(2000), 40);
    if (value === 9) nine = rect;
    if (value === 10) {
      assert(rect.w > nine.w + 1, `9→10 must remeasure width: ${nine.w}→${rect.w}`);
      assert(Math.abs(rect.x + rect.w / 2 - nine.x - nine.w / 2) < 1,
        "updated value must remain centered");
      await shot("stepper-digit-growth");
      assertRegionHasInk(`${DIR}/story-stepper-digit-growth.png`, rect, "stepper two-digit label", 10);
    }
  }
});

test("TagsInput: 交互 — 逗号提交 + × 删除", async () => {
  await switchTo("tags");
  await clickTestId("story.tags.input");
  await type_("gpu,");
  await sleep(350);
  let out: string[] = [];
  let tr = await query("story.tags.wrapper");
  if (tr[0]) collectText(tr[0], out);
  appendLog(`  tags after commit: ${out.join(" │ ")}`);
  assert(out.includes("gpu"), `逗号提交后应有 gpu tag — ${out.join(" │ ")}`);
  await shot("tags-committed");
});

test("FileUpload: 交互 — Browse 回填文件行", async () => {
  await switchTo("upload");
  const tree = await query("story.upload.wrapper");
  const browse = findRectByText(tree[0], "Browse…");
  assert(browse, "找不到 Browse 按钮");
  await clickAt(browse.x + browse.w / 2, browse.y + browse.h / 2);
  await sleep(250);
  const out: string[] = [];
  const t1 = await query("story.upload.wrapper");
  if (t1[0]) collectText(t1[0], out);
  appendLog(`  upload after browse: ${out.join(" │ ")}`);
  assert(out.join(" ").includes("demo-file-1.txt"), `Browse 后应出现文件行 — ${out.join(" │ ")}`);
});

test("FileUpload: 拖放 — Finder 拖入文件（程序化注入）", async () => {
  await switchTo("upload");
  // 真 Finder 拖放没法自动化：走 /drag 注入 entered → updated → dropped，
  // 与平台 NSDragging 回调进 Cx.handleDrag 的是同一条路径。
  const zone = (await query("story.upload.dropzone"))[0];
  assert(zone, "找不到 dropzone");
  const cx0 = zone.rect.x + zone.rect.w / 2;
  const cy0 = zone.rect.y + zone.rect.h / 2;

  // 悬停高亮：entered 后截图（drop zone 边框/底色应变化）
  await dragAt(cx0, cy0, 0);
  await dragAt(cx0, cy0, 1);
  await sleep(120);
  await shot("upload-drag-hover");

  // 放下两个文件（换行分隔），逐条添加
  await dragAt(cx0, cy0, 3, "/tmp/dropped-one.txt\n/tmp/dropped-two.txt");
  await sleep(250);

  const out: string[] = [];
  const tree = await query("story.upload.wrapper");
  if (tree[0]) collectText(tree[0], out);
  appendLog(`  upload after drop: ${out.join(" │ ")}`);
  assert(
    out.join(" ").includes("dropped-one.txt"),
    `拖入后应出现 dropped-one.txt — ${out.join(" │ ")}`,
  );
  assert(
    out.join(" ").includes("dropped-two.txt"),
    `换行分隔的第二个文件也应添加 — ${out.join(" │ ")}`,
  );
  await shot("upload-dropped");
});

test("DataTable: 交互 — 翻页 + 筛选", async () => {
  await switchTo("datatable");
  // 翻页：Next → Page 2，首行变 Dave（Next 按钮 rect 从数据树里找）
  const tree0 = await query("story.datatable.table");
  const texts0: string[] = [];
  if (tree0[0]) collectText(tree0[0], texts0);
  assert(texts0.join(" ").includes("Page 1 / 3"), `初始应在第 1 页 — ${texts0.join(" │ ")}`);
  // 找 Next 按钮节点 rect（递归找 text === "Next" 的节点的父 rect）
  function findRect(node: any, label: string): any {
    if (node?.text === label) return node.rect ?? null;
    for (const c of node?.children ?? []) {
      const r = findRect(c, label);
      if (r) return r;
    }
    return null;
  }
  const nextRect = findRect(tree0[0], "Next");
  assert(nextRect, "找不到 Next 按钮");
  await clickAt(nextRect.x + nextRect.w / 2, nextRect.y + nextRect.h / 2);
  await sleep(250);
  const texts1: string[] = [];
  const tree1 = await query("story.datatable.table");
  if (tree1[0]) collectText(tree1[0], texts1);
  const joined1 = texts1.join(" │ ");
  appendLog(`  datatable after Next: ${joined1}`);
  assert(joined1.includes("Page 2 / 3"), `Next 后应在第 2 页 — ${joined1}`);
  assert(joined1.includes("Dave"), `第 2 页应含 Dave — ${joined1}`);

  // 筛选：输入 "admin" → 只 Alice/Frank，Page 1 / 1
  await clickTestId("story.datatable.filter");
  await type_("admin");
  await sleep(400);
  const texts2: string[] = [];
  const tree2 = await query("story.datatable.table");
  if (tree2[0]) collectText(tree2[0], texts2);
  const joined2 = texts2.join(" │ ");
  appendLog(`  datatable filtered: ${joined2}`);
  assert(joined2.includes("Alice") && joined2.includes("Frank"), `筛选 admin 应含 Alice+Frank — ${joined2}`);
  assert(joined2.includes("Page 1 / 1"), `筛选后应 1 页 — ${joined2}`);
  await shot("datatable-filtered");
});

test("ComboBox: 交互 — 输入过滤 + 点选写回", async () => {
  await switchTo("combobox");
  await clickTestId("story.combobox.input"); // 聚焦输入框
  await type_("an");
  await sleep(400);
  await shot("combobox-open");
  // 过滤后面板只应有 Banana / Mango 可见（其余行高 0，仍在树中但文本节点高度 0）
  const tree = await query("story.combobox.panel");
  const out: string[] = [];
  if (tree[0]) collectText(tree[0], out);
  const joined = out.join(" │ ");
  appendLog(`  combobox filtered panel texts: ${joined}`);
  assert(joined.includes("Banana"), `combobox 过滤后缺 Banana — 实际: ${joined}`);
  // 点选 Banana（找可见行位置）
  const pos = await screenPos("story.combobox.panel");
  await clickAt(pos.x + 40, pos.y + 20); // 第一可见行
  await sleep(300);
  const input = await inputState("story.combobox.input");
  appendLog(`  combobox input after select: ${JSON.stringify(input)}`);

  // 回归：无匹配时旧实现只把 option 行高设为 0，label 仍溢出并全部叠在
  // empty state 上。Pvnqs 版本要求隐藏项退出布局/绘制，只保留居中空态。
  await switchTo("combobox");
  await clickTestId("story.combobox.input");
  // 兼容点选写回后的 suppress-change 一帧：第二次输入必须真实触发过滤。
  await type_("z");
  await sleep(100);
  await type_("zz");
  await sleep(400);
  appendLog(`  combobox no-match input: ${JSON.stringify(await inputState("story.combobox.input"))}`);
  const noMatchTree = await query("story.combobox.panel");
  const noMatchTexts: string[] = [];
  if (noMatchTree[0]) collectText(noMatchTree[0], noMatchTexts);
  appendLog(`  combobox no-match tree texts: ${noMatchTexts.join(" │ ")}`);
  assert(noMatchTexts.includes("No results found"), `无匹配时缺空态 — 实际: ${noMatchTexts.join(" │ ")}`);
  await shot("combobox-no-results");
});

test("Select: puQEf component family", async () => {
  await switchTo("select");
  const family = await query("story.select.family");
  assert(family.length === 1, `puQEf family root 缺失 — got ${family.length}`);
  await shot("select-puqef-rest");

  const near = (actual: number, expected: number, label: string, tolerance = 1) => {
    const delta = Math.abs(actual - expected);
    appendLog(`  ${label}: actual=${actual.toFixed(2)} expected=${expected.toFixed(2)} delta=${delta.toFixed(2)}`);
    assert(delta <= tolerance, `${label}: ${actual} != ${expected} (±${tolerance})`);
  };
  const opacityOf = (node: any): number => node.opacity ?? 1;
  const rotateOf = (node: any): number => node.rotate ?? 0;
  const withIconTrigger = (await query("story.select.with-icon"))[0];
  near(withIconTrigger.rect.w, 352, "puQEf trigger width");
  assert(withIconTrigger.rect.h >= 38 && withIconTrigger.rect.h <= 41, `LG trigger height ${withIconTrigger.rect.h} 不在 puQEf 38..41`);

  // 真实单选：打开 Popover → 选 Option 2 → trigger 写回。
  await clickTestId("story.select.with-icon");
  await sleep(55);
  const openingChevron = (await query("story.select.with-icon.chevron"))[0];
  appendLog(`  opening chevron captured rotate=${rotateOf(openingChevron).toFixed(3)} rad`);
  await shot("select-puqef-with-icon-opening-rotate-mid");
  await sleep(160);
  const openedChevron = (await query("story.select.with-icon.chevron"))[0];
  near(rotateOf(openedChevron), Math.PI, "opened chevron rotates 180deg", 0.06);
  await shot("select-puqef-with-icon-open");
  const withIconPanel = await query("story.select.with-icon.panel");
  const texts: string[] = [];
  if (withIconPanel[0]) collectText(withIconPanel[0], texts);
  const joined = texts.join(" │ ");
  for (const option of ["Option 1", "Option 2", "Option 3", "Option 4"])
    assert(joined.includes(option), `Select panel 缺 ${option} — 实际: ${joined}`);
  await clickTestId("story.select.with-icon.option-2");
  await sleep(55);
  const closingChevron = (await query("story.select.with-icon.chevron"))[0];
  appendLog(`  closing chevron captured rotate=${rotateOf(closingChevron).toFixed(3)} rad`);
  await shot("select-puqef-with-icon-closing-rotate-mid");
  await sleep(160);
  const closedChevron = (await query("story.select.with-icon.chevron"))[0];
  near(rotateOf(closedChevron), 0, "closed chevron returns to 0deg", 0.06);
  await shot("select-puqef-with-icon-selected-option-2");
  const selectedText = await storyTexts("select");
  assert(selectedText.includes("Option 2"), `单选未写回 trigger: ${selectedText}`);

  // Clearable 的 append 始终只有一个 icon 位。默认与普通 Select 一样显示
  // chevron；选中态 hover trigger 时，absolute icon-only clear 原位覆盖 chevron。
  await mouseMove(-10, -10);
  await sleep(100);
  await shot("select-puqef-clearable-selected-rest");
  const clearButtonRest = (await query("story.select.clear"))[0];
  const clearChevronRest = (await query("story.select.clearable.chevron"))[0];
  const clearAppendRest = (await query("story.select.clearable.append"))[0];
  const clearAppendCompRest = (await query("story.select.clearable.append-comp"))[0];
  assert(clearButtonRest.opacity === 0,
    `selected rest 必须只显示 chevron — clear opacity=${clearButtonRest.opacity}`);
  assert(clearChevronRest.opacity === undefined || clearChevronRest.opacity === 1,
    `selected rest chevron 必须可见 — opacity=${clearChevronRest.opacity}`);
  near(clearAppendCompRest.rect.w, 20, "fixed append overlay width", 0.75);
  near(clearAppendRest.rect.w, 20, "shell append remains one icon wide", 0.75);

  const clearablePos = await screenPos("story.select.clearable");
  await mouseMove(clearablePos.x + 48, clearablePos.y + clearablePos.h / 2);
  const clearButtonFadeIn = (await query("story.select.clear"))[0];
  const clearChevronFadeOut = (await query("story.select.clearable.chevron"))[0];
  appendLog(`  fade-in capture: clear=${opacityOf(clearButtonFadeIn).toFixed(3)} chevron=${opacityOf(clearChevronFadeOut).toFixed(3)}`);
  await shot("select-puqef-clearable-fade-in-mid");
  await sleep(180);
  await shot("select-puqef-clearable-selected-trigger-hover");
  const clearButtonHover = (await query("story.select.clear"))[0];
  const clearChevronHover = (await query("story.select.clearable.chevron"))[0];
  near(opacityOf(clearButtonHover), 1, "selected hover clear fade-in settles", 0.02);
  near(opacityOf(clearChevronHover), 0, "selected hover chevron fade-out settles", 0.02);
  near(clearButtonHover.rect.x, clearChevronHover.rect.x, "clear overlays chevron x", 0.75);
  near(clearButtonHover.rect.y, clearChevronHover.rect.y, "clear overlays chevron y", 0.75);
  near(clearButtonHover.rect.w, clearChevronHover.rect.w, "clear matches chevron width", 0.75);
  near(clearButtonHover.rect.h, clearChevronHover.rect.h, "clear matches chevron height", 0.75);
  assert((clearButtonHover.component ?? "").includes("Button"),
    `clear 必须是真正的 icon-only Button — component=${clearButtonHover.component}`);

  await clickTestId("story.select.clearable");
  await sleep(60);
  await shot("select-puqef-clearable-opening-selected");
  await sleep(140);
  await shot("select-puqef-clearable-open-selected");
  const clearButtonOpen = (await query("story.select.clear"))[0];
  const clearChevronOpen = (await query("story.select.clearable.chevron"))[0];
  const clearAppendOpen = (await query("story.select.clearable.append"))[0];
  const clearAppendCompOpen = (await query("story.select.clearable.append-comp"))[0];
  const clearChevronUpOpen = (await query("story.select.clearable.chevron-up"))[0];
  const clearChevronDownOpen = (await query("story.select.clearable.chevron-down"))[0];
  near(clearButtonOpen.rect.x, clearChevronOpen.rect.x, "open clear overlays chevron x", 0.75);
  near(clearButtonOpen.rect.w, clearChevronOpen.rect.w, "open clear matches chevron width", 0.75);
  near(clearAppendCompOpen.rect.w, 20, "selected append stays one icon wide", 0.75);
  near(clearAppendOpen.rect.w, clearAppendCompOpen.rect.w, "shell append contains LONiE Box", 0.75);
  assert(opacityOf(clearButtonOpen) > 0.98 && opacityOf(clearChevronOpen) < 0.02,
    `selected open hover 必须由 clear 覆盖 chevron — clear=${opacityOf(clearButtonOpen)} chevron=${opacityOf(clearChevronOpen)}`);
  assert(opacityOf(clearChevronUpOpen) === 0 && opacityOf(clearChevronDownOpen) === 1,
    `Select 必须只使用一个 down chevron — up=${opacityOf(clearChevronUpOpen)} down=${opacityOf(clearChevronDownOpen)}`);
  near(rotateOf(clearChevronDownOpen), Math.PI, "clearable open chevron rotation target", 0.06);
  await clickTestId("story.select.clearable");
  await sleep(200);
  await shot("select-puqef-clearable-reclosed-selected");

  await mouseMove(-10, -10);
  const clearButtonFadeOut = (await query("story.select.clear"))[0];
  const clearChevronFadeIn = (await query("story.select.clearable.chevron"))[0];
  appendLog(`  fade-out capture: clear=${opacityOf(clearButtonFadeOut).toFixed(3)} chevron=${opacityOf(clearChevronFadeIn).toFixed(3)}`);
  await shot("select-puqef-clearable-fade-out-mid");
  await sleep(180);
  await shot("select-puqef-clearable-reclosed-selected-rest");
  const clearButtonReclosedRest = (await query("story.select.clear"))[0];
  const clearChevronReclosedRest = (await query("story.select.clearable.chevron"))[0];
  const clearChevronDownReclosedRest = (await query("story.select.clearable.chevron-down"))[0];
  assert(opacityOf(clearButtonReclosedRest) < 0.02 && opacityOf(clearChevronReclosedRest) > 0.98 &&
    opacityOf(clearChevronDownReclosedRest) === 1,
    `离开 selected trigger 后必须恢复 down chevron — clear=${opacityOf(clearButtonReclosedRest)} chevron=${opacityOf(clearChevronReclosedRest)}`);

  // 真实 icon-only Button 的 hover / pressed / click 都留截图：
  // 初始 Option 1 → hover trigger 显示 x → hover x → press x → release/click → placeholder。
  await mouseMove(clearablePos.x + 48, clearablePos.y + clearablePos.h / 2);
  await sleep(80);
  const clearPos = await screenPos("story.select.clear");
  await mouseMove(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  await sleep(120);
  await shot("select-puqef-clearable-clear-hover");
  await mouseDown(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  await sleep(80);
  await shot("select-puqef-clearable-clear-pressed");
  await mouseUp(clearPos.x + clearPos.w / 2, clearPos.y + clearPos.h / 2);
  const clearedButtonFadeOut = (await query("story.select.clear"))[0];
  appendLog(`  clear-click fade-out capture: clear=${opacityOf(clearedButtonFadeOut).toFixed(3)}`);
  await shot("select-puqef-clearable-cleared-fade-out-mid");
  await sleep(180);
  await shot("select-puqef-clearable-cleared");
  const clearableTree = await query("story.select.clearable");
  const clearableTexts: string[] = [];
  if (clearableTree[0]) collectText(clearableTree[0], clearableTexts);
  assert(clearableTexts.includes("Select an option..."), `clear 后未恢复 placeholder: ${clearableTexts.join(" │ ")}`);
  const clearAppend = (await query("story.select.clearable.append"))[0];
  const clearedAppendComp = (await query("story.select.clearable.append-comp"))[0];
  const clearChevron = (await query("story.select.clearable.chevron"))[0];
  const clearedTrigger = (await query("story.select.clearable"))[0];
  const clearedButton = (await query("story.select.clear"))[0];
  const clearedChevronDown = (await query("story.select.clearable.chevron-down"))[0];
  near(clearAppend.rect.w, clearChevron.rect.w, "cleared append stays one icon wide", 0.75);
  near(clearedAppendComp.rect.w, clearChevron.rect.w, "empty overlay Box stays one icon wide", 0.75);
  near(clearChevron.rect.x + clearChevron.rect.w, clearedTrigger.rect.x + clearedTrigger.rect.w - 16,
    "cleared LG chevron stays at right padding", 0.75);
  assert(opacityOf(clearedButton) < 0.02, `cleared state 的 clear 必须隐藏 — opacity=${opacityOf(clearedButton)}`);
  assert(opacityOf(clearedChevronDown) === 1,
    `cleared closed state 必须显示 chevron-down — opacity=${opacityOf(clearedChevronDown)}`);
  await clickTestId("story.select.clearable");
  await sleep(55);
  await shot("select-puqef-clearable-opening-empty-rotate-mid");
  await sleep(145);
  await shot("select-puqef-clearable-open-empty");
  await clickTestId("story.select.clearable");
  await sleep(55);
  await shot("select-puqef-clearable-closing-empty-rotate-mid");
  await sleep(145);
  await shot("select-puqef-clearable-reclosed-empty");

  // 真实搜索：输入 3 过滤，点选后写回 Input 并关闭。
  await clickTestId("story.select.trigger");
  await sleep(250);
  await shot("select-puqef-search-open-before-hover");
  const searchHover = await screenPos("story.select.search.option-1");
  await mouseMove(searchHover.x - 20, searchHover.y + 12);
  await sleep(60);
  await mouseMove(searchHover.x + 28, searchHover.y + 12);
  await sleep(180);
  await shot("select-puqef-search-open-default");
  const searchDefaultPanel = (await query("story.select.panel"))[0];
  const searchOption1 = (await query("story.select.search.option-1"))[0];
  const searchIcon = (await query("story.select.search.icon"))[0];
  const searchInputAtRest = (await query("story.select.search.input"))[0];
  near(searchDefaultPanel.rect.w, 352, "puQEf search panel width");
  near(searchDefaultPanel.rect.h, 112, "puQEf search panel height", 2);
  near(searchInputAtRest.rect.x - (searchIcon.rect.x + searchIcon.rect.w), 8, "puQEf search icon/text gap", 0.75);
  assertColorNear(
    centerPixel(`${DIR}/story-select-puqef-search-open-default.png`, {
      x: searchOption1.rect.x + searchOption1.rect.w * 0.5,
      y: searchOption1.rect.y + searchOption1.rect.h * 0.5,
      w: 4,
      h: 4,
    }),
    [245, 245, 245],
    "puQEf searchable hover background",
    5,
  );
  await clickTestId("story.select.trigger");
  await sleep(120);
  await shot("select-puqef-search-closed-after-trigger");
  await clickTestId("story.select.search.input");
  await sleep(180);
  await shot("select-puqef-search-focused-open");
  await type_("3");
  await sleep(220);
  const searchTrigger = (await query("story.select.trigger"))[0];
  const searchPanel = await waitFor(async () => (await query("story.select.panel"))[0] ?? null, 2500, 40);
  near(searchTrigger.rect.w, 352, "search trigger width");
  near(searchPanel.rect.w, 352, "search panel width");
  assert(searchTrigger.rect.h >= 36 && searchTrigger.rect.h <= 40, `search trigger height ${searchTrigger.rect.h} 不在 puQEf 36..40`);
  await shot("select-puqef-search-open");
  await clickTestId("story.select.search.option-3");
  await sleep(180);
  await shot("select-puqef-search-selected-option-3");
  const searchInput = await inputState("story.select.search.input");
  assert(searchInput.buffer === "Option 3", `search select 未写回 Option 3: ${JSON.stringify(searchInput)}`);
  // Reopen the committed value as a separate transition; this catches stale
  // filter/selection styling that is invisible in the one-way happy path.
  await clickTestId("story.select.trigger");
  await sleep(180);
  await shot("select-puqef-search-reopened-selected-option-3");
  await clickTestId("story.select.trigger");
  await sleep(120);
  await shot("select-puqef-search-reclosed-selected-option-3");

  // 真实多选：勾选 Option 3 后 panel 保持展开，tag 立即出现；
  // 点 tag 的 x 后再移除。
  await clickTestId("story.select.multiple-lg");
  await sleep(220);
  await shot("select-puqef-multiple-lg-open-before-hover");
  const hoverPos = await screenPos("story.select.multiple-lg.option-1");
  await mouseMove(hoverPos.x + 24, hoverPos.y + 12);
  await sleep(120);
  // Visual baseline first: exactly the two initial tags shown in `puQEf`.
  await shot("select-puqef-multiple-lg-open");
  const multipleLgPanel = (await query("story.select.multiple-lg.panel"))[0];
  const multipleLgOption1 = (await query("story.select.multiple-lg.option-1"))[0];
  near(multipleLgPanel.rect.w, 352, "puQEf multiple LG panel width");
  near(multipleLgPanel.rect.h, 152, "puQEf multiple LG panel height", 2);
  assertColorNear(
    centerPixel(`${DIR}/story-select-puqef-multiple-lg-open.png`, {
      x: multipleLgOption1.rect.x + multipleLgOption1.rect.w * 0.5,
      y: multipleLgOption1.rect.y + multipleLgOption1.rect.h * 0.5,
      w: 4,
      h: 4,
    }),
    [245, 245, 245],
    "puQEf multiple hover background",
    5,
  );
  await clickTestId("story.select.multiple-lg.option-3");
  await sleep(150);
  let tag3 = await query("story.select.multiple-lg.tag-3");
  assert(tag3[0]?.rect.w > 0 && tag3[0]?.rect.h > 0, "多选后 Option 3 tag 未显示");
  await shot("select-puqef-multiple-lg-selected-3");
  await clickTestId("story.select.multiple-lg.tag-3-close");
  await sleep(150);
  await shot("select-puqef-multiple-lg-tag-3-removed");
  tag3 = await query("story.select.multiple-lg.tag-3");
  assert(!tag3[0] || tag3[0].rect.h === 0, "点 tag close 后 Option 3 仍显示");
  await clickTestId("story.select.multiple-lg");
  await sleep(150);
  await shot("select-puqef-multiple-lg-closed");

  // Searchable multiple LG: open → close → focus input → filter → select → close.
  await clickTestId("story.select.multiple-search-lg");
  await sleep(180);
  await shot("select-puqef-multiple-search-lg-open");
  await clickTestId("story.select.multiple-search-lg");
  await sleep(120);
  await shot("select-puqef-multiple-search-lg-closed");
  await clickTestId("story.select.multiple-search-lg.input");
  await sleep(180);
  await shot("select-puqef-multiple-search-lg-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-puqef-multiple-search-lg-filtered-3");
  await clickTestId("story.select.multiple-search-lg.option-3");
  await sleep(150);
  await shot("select-puqef-multiple-search-lg-selected-option-3");
  const multiSearchLgContent = (await query("story.select.multiple-search-lg.content"))[0];
  const multiSearchLgInput = (await query("story.select.multiple-search-lg.input"))[0];
  const multiSearchLgAppend = (await query("story.select.multiple-search-lg.append"))[0];
  appendLog(`  multiple-search LG slots: content=${JSON.stringify(multiSearchLgContent.rect)} input=${JSON.stringify(multiSearchLgInput.rect)} append=${JSON.stringify(multiSearchLgAppend.rect)}`);
  assert(
    multiSearchLgInput.rect.x >= multiSearchLgContent.rect.x && multiSearchLgInput.rect.x < multiSearchLgAppend.rect.x,
    `multiple searchable input 起点不在 content slot: input=${JSON.stringify(multiSearchLgInput.rect)} content=${JSON.stringify(multiSearchLgContent.rect)}`,
  );
  assert(
    multiSearchLgContent.rect.x + multiSearchLgContent.rect.w <= multiSearchLgAppend.rect.x - 7,
    `multiple searchable content 侵入 append slot: content=${JSON.stringify(multiSearchLgContent.rect)} append=${JSON.stringify(multiSearchLgAppend.rect)}`,
  );
  assertColorNear(
    centerPixel(`${DIR}/story-select-puqef-multiple-search-lg-selected-option-3.png`, {
      x: multiSearchLgContent.rect.x + multiSearchLgContent.rect.w + 2,
      y: multiSearchLgAppend.rect.y + multiSearchLgAppend.rect.h * 0.5 - 2,
      w: 4,
      h: 4,
    }),
    [250, 250, 250],
    "multiple searchable content/append paint gap",
    4,
  );
  await clickTestId("story.select.multiple-search-lg");
  await sleep(120);
  await shot("select-puqef-multiple-search-lg-reclosed");

  // MD / XS 也打开真实 Popover 单独对照，不只看关闭 trigger。
  await clickTestId("story.select.multiple-md");
  await sleep(250);
  const mdPanel = (await query("story.select.multiple-md.panel"))[0];
  near(mdPanel.rect.h, 152, "puQEf multiple MD panel height", 2);
  await shot("select-puqef-multiple-md-open");
  await clickTestId("story.select.multiple-md");
  await sleep(120);
  await shot("select-puqef-multiple-md-closed");

  // Repeat every searchable transition at MD; size-specific reflow bugs have
  // previously only appeared while the query text or a new tag was present.
  await clickTestId("story.select.multiple-search-md");
  await sleep(180);
  await shot("select-puqef-multiple-search-md-open");
  await clickTestId("story.select.multiple-search-md");
  await sleep(120);
  await shot("select-puqef-multiple-search-md-closed");
  await clickTestId("story.select.multiple-search-md.input");
  await sleep(180);
  await shot("select-puqef-multiple-search-md-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-puqef-multiple-search-md-filtered-3");
  await clickTestId("story.select.multiple-search-md.option-3");
  await sleep(150);
  await shot("select-puqef-multiple-search-md-selected-option-3");
  await clickTestId("story.select.multiple-search-md");
  await sleep(120);
  await shot("select-puqef-multiple-search-md-reclosed");

  await clickTestId("story.select.multiple-xs");
  await sleep(250);
  const xsTrigger = (await query("story.select.multiple-xs"))[0];
  const xsPanel = (await query("story.select.multiple-xs.panel"))[0];
  // 控件高度统一：XS = control scale xs（padding_y×2 + 行高 = 20）。puQEf 设计稿原为 23。
  near(xsTrigger.rect.h, 20, "XS trigger height", 0.75);
  near(xsPanel.rect.h, 118, "puQEf multiple XS panel height", 2);
  await shot("select-puqef-multiple-xs-open");
  await clickTestId("story.select.multiple-xs");
  await sleep(120);
  await shot("select-puqef-multiple-xs-closed");

  // XS searchable gets the same complete state sequence, including the
  // narrow trigger after a second tag is inserted.
  await clickTestId("story.select.multiple-search-xs");
  await sleep(180);
  await shot("select-puqef-multiple-search-xs-open");
  await clickTestId("story.select.multiple-search-xs");
  await sleep(120);
  await shot("select-puqef-multiple-search-xs-closed");
  await clickTestId("story.select.multiple-search-xs.input");
  await sleep(180);
  await shot("select-puqef-multiple-search-xs-focused-open");
  await type_("3");
  await sleep(180);
  await shot("select-puqef-multiple-search-xs-filtered-3");
  await clickTestId("story.select.multiple-search-xs.option-3");
  await sleep(150);
  await shot("select-puqef-multiple-search-xs-selected-option-3");
  await clickTestId("story.select.multiple-search-xs");
  await sleep(120);
  await shot("select-puqef-multiple-search-xs-reclosed");
});

test("Menu: 交互 — 点开显示 items", async () => {
  await switchTo("menu");
  const pos = await screenPos("story.menu.trigger");
  await clickAt(pos.x + 30, pos.y + 12); // 点 trigger 按钮
  await sleep(350);
  await shot("menu-open");
  // 打开后的菜单项在窗口 portal root（popover content 已 portal 化，不在
  // content 面板子树里）—— 从整棵窗口树收文本
  const root = await tree();
  const out: string[] = [];
  collectText(root, out);
  const joined = out.join(" │ ");
  appendLog(`  menu opened, texts: ${joined}`);
  for (const item of ["Cut", "Copy", "Delete"]) {
    assert(joined.includes(item), `menu 打开后缺 item "${item}" — 实际: ${joined}`);
  }
});

test("damage-rect: modal 内按钮悬停触发部分重绘（retained 层只重画脏区）", async () => {
  // 场景选择：retained 只覆盖 promoted overlay（普通内容面板不促升）。
  // Modal 弹层内容在层内平铺捕获（非单一嵌套 fold），悬停按钮只改一小块
  // bg → per-item diff 出小脏区 → partial。
  await switchTo("modal");
  const btn = await screenPos("story.modal.open");
  await clickAt(btn.x + btn.w / 2, btn.y + btn.h / 2);
  await sleep(900); // 等入场动画 settle → retained 纹理 primed
  const before = await stats();
  const dlg = (await query("story.modal.dialog"))[0];
  assert(dlg != null, "modal dialog 未打开");
  const okBtn = await screenPos("story.modal.ok");
  await mouseMove(okBtn.x + okBtn.w / 2, okBtn.y + okBtn.h / 2);
  await sleep(400);
  // screenshot is the presentation barrier for file-RPC. Reading stats before
  // it races the renderer: the pointer command has been acknowledged, but the
  // corresponding retained-surface frame may not have been published yet.
  await shot("modal-hover-partial-repaint");
  const after = await stats();
  appendLog(
    `  partial: ${before.retained_partial_repaints} -> ${after.retained_partial_repaints}; ` +
    `hits ${before.retained_hits} -> ${after.retained_hits}; misses ${before.retained_misses} -> ${after.retained_misses}`,
  );
  // 收尾：点 overlay 空白处关掉 modal（close_on_overlay），别影响后续用例
  await clickAt(1000, 60);
  await sleep(500);
  assert(
    after.retained_partial_repaints > before.retained_partial_repaints,
    `modal 内按钮悬停应触发 damage-rect 部分重绘 — partial_repaints ${before.retained_partial_repaints} -> ${after.retained_partial_repaints}`,
  );
});

// ── zindex：系统 z-index manager 验证（tier 基线 + overflow 逃逸 + 嵌套继承）──

function rectsOverlap(a: { x: number; y: number; w: number; h: number }, b: { x: number; y: number; w: number; h: number }): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

test("zindex: 兄弟 z_index 覆盖 DOM 顺序（red z=3 最上）", async () => {
  await switchTo("zindex");
  await sleep(400);
  await shot("zindex-static");
  const arena = (await query("story.zindex.siblings"))[0];
  assert(arena != null, "siblings arena 不存在");
  // 三块 130x80 交叠区：x∈[60,130], y∈[20,80]（arena 局部）→ 采样其中心
  const px = centerPixel(`${DIR}/story-zindex-static.png`, { x: arena.rect.x + 60, y: arena.rect.y + 20, w: 70, h: 60 });
  assertColorNear(px, [220, 50, 47], "三兄弟交叠区必须是 red（z=3, DOM 最先）", 20);
});

test("zindex: overflow 容器内 popover 溢出裁剪并盖住障碍物", async () => {
  await switchTo("zindex");
  const click = await clickTestId("story.zindex.pop.trigger");
  assert(click.ok === true, `popover trigger click failed: ${JSON.stringify(click)}`);
  const slab = await waitFor(async () => {
    const node = (await query("story.zindex.pop.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const obstacle = (await query("story.zindex.obstacle"))[0];
  assert(obstacle != null, "obstacle 不存在");
  // 前置条件：slab 必须真的与障碍物交叠，否则下面的像素断言在测空气
  appendLog(`  slab=${JSON.stringify(slab.rect)} obstacle=${JSON.stringify(obstacle.rect)}`);
  assert(rectsOverlap(slab.rect, obstacle.rect), "布局漂移：popover slab 未与 obstacle 交叠，断言失去意义");
  await shot("zindex-popover-open");
  // 采样 slab 与 obstacle 交叠区中心 —— 必须是 indigo（popover 在上），
  // 层级破坏时会读到 orange（障碍物）或 yellow（transform 菱形）。
  const ix = Math.max(slab.rect.x, obstacle.rect.x);
  const iy = Math.max(slab.rect.y, obstacle.rect.y);
  const iw = Math.min(slab.rect.x + slab.rect.w, obstacle.rect.x + obstacle.rect.w) - ix;
  const ih = Math.min(slab.rect.y + slab.rect.h, obstacle.rect.y + obstacle.rect.h) - iy;
  const px = centerPixel(`${DIR}/story-zindex-popover-open.png`, { x: ix, y: iy, w: iw, h: ih });
  assertColorNear(px, [79, 70, 229], "popover slab 必须盖住障碍物", 20);
  // 收尾：点远处空白关闭
  await clickAt(1000, 600);
  await sleep(400);
});

test("zindex: tooltip tier 溢出裁剪并盖住障碍物", async () => {
  await switchTo("zindex");
  const trig = await screenPos("story.zindex.tip.trigger");
  await mouseMove(trig.x + trig.w / 2, trig.y + trig.h / 2);
  const tip = await waitFor(async () => {
    const node = (await query("story.zindex.tip.content"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const obstacle = (await query("story.zindex.obstacle"))[0];
  appendLog(`  tip=${JSON.stringify(tip.rect)} obstacle=${JSON.stringify(obstacle.rect)}`);
  assert(rectsOverlap(tip.rect, obstacle.rect), "布局漂移：tooltip 未与 obstacle 交叠，断言失去意义");
  await shot("zindex-tooltip-open");
  // 采样 tooltip 与障碍物交叠区的最深像素：tooltip 深色气泡在上 → 近黑；
  // 被障碍物盖住 → 最深也只有纯橙 (255,150,40) → 断言红。
  const ix = Math.max(tip.rect.x, obstacle.rect.x);
  const iy = Math.max(tip.rect.y, obstacle.rect.y);
  const iw = Math.min(tip.rect.x + tip.rect.w, obstacle.rect.x + obstacle.rect.w) - ix;
  const ih = Math.min(tip.rect.y + tip.rect.h, obstacle.rect.y + obstacle.rect.h) - iy;
  const dk = darkestPixel(`${DIR}/story-zindex-tooltip-open.png`, { x: ix, y: iy, w: iw, h: ih });
  appendLog(`  tooltip∩obstacle darkest: (${dk.join(",")})`);
  assert(dk[0] < 90 && dk[1] < 90 && dk[2] < 90, `tooltip 气泡未盖住障碍物 — 交叠区最深像素 (${dk.join(",")})`);
  await mouseMove(20, 400);
  await sleep(400);
});

test("zindex: modal 内嵌 popover 压过 dialog（嵌套 tier 继承）", async () => {
  await switchTo("zindex");
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const popClick = await clickTestId("story.zindex.modal.pop.trigger");
  assert(popClick.ok === true, `nested popover trigger click failed: ${JSON.stringify(popClick)}`);
  const slab = await waitFor(async () => {
    const node = (await query("story.zindex.modal.pop.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal-popover");
  const px = centerPixel(`${DIR}/story-zindex-modal-popover.png`, slab.rect);
  assertColorNear(px, [79, 70, 229], "modal 内 popover slab 必须在 dialog 之上", 20);
  // 收尾：两次 escape 依次关 popover 和 modal
  await key("escape");
  await sleep(300);
  await key("escape");
  await sleep(500);
});

test("zindex: modal body 里的 tooltip 恒顶（tooltip tier）", async () => {
  await switchTo("zindex");
  // Prior z-index cases close overlays with Escape without moving the physical
  // hover coordinate. Establish a fresh outside -> trigger edge so this case
  // does not inherit an already-hovered ancestor from the previous case.
  await mouseMove(-10, -10);
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const trig = await screenPos("story.zindex.modal.tip.trigger");
  await mouseMove(trig.x + trig.w / 2, trig.y + trig.h / 2);
  // 等气泡真正完全可见（有效不透明度含祖先上的入场淡入），而不是 sleep 猜时长：
  // 负载高时固定 300ms 截到半透明气泡，被误判为"被盖/未画出"。
  const tip = await waitFor(async () => {
    const node = (await query("story.zindex.modal.tip.content"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal-tooltip");
  // 深色气泡画在浅色 dialog 之上：气泡区最深像素近黑
  const dk = darkestPixel(`${DIR}/story-zindex-modal-tooltip.png`, tip.rect);
  appendLog(`  modal tooltip darkest: (${dk.join(",")})`);
  assert(dk[0] < 90 && dk[1] < 90 && dk[2] < 90, `modal 内 tooltip 未画出/被盖 — 最深像素 (${dk.join(",")})`);
  await mouseMove(20, 400);
  await sleep(300);
  await key("escape");
  await sleep(500);
});

test("zindex: 三级嵌套 modal → popover → modal2（tier 链）", async () => {
  await switchTo("zindex");
  const openClick = await clickTestId("story.zindex.modal.open");
  assert(openClick.ok === true, `modal trigger click failed: ${JSON.stringify(openClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.dialog"))[0];
    return node != null && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const popClick = await clickTestId("story.zindex.modal.pop.trigger");
  assert(popClick.ok === true, `nested popover trigger click failed: ${JSON.stringify(popClick)}`);
  await waitFor(async () => {
    const node = (await query("story.zindex.modal.pop.slab"))[0];
    return node != null && node.rect.w > 0 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  // 点 modal2 触发器前等 popover 入场完成：节点先上树（rect 已有）但入场期间还不接受命中，
  // 这时点下去会落到下层 modal 的遮罩上（hit 日志实锤：命中 Modal 而非按钮）。
  await waitFor(async () => {
    const node = (await query("story.zindex.modal2.open"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const modal2Click = await clickTestId("story.zindex.modal2.open");
  assert(modal2Click.ok === true, `modal2 trigger click failed: ${JSON.stringify(modal2Click)}`);
  // 等 modal2 真正完全可见（入场淡入挂在祖先上），而不是 sleep 猜时长。
  const slab2 = await waitFor(async () => {
    const node = (await query("story.zindex.modal2.slab"))[0];
    return node != null && node.rect.w > 0 && (node.effective_opacity ?? 0) >= 0.99 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await shot("zindex-modal2");
  const px = centerPixel(`${DIR}/story-zindex-modal2.png`, slab2.rect);
  assertColorNear(px, [20, 150, 140], "popover 里开出的 modal2 必须在最上（teal slab 可见）", 20);
  // 收尾：逐层 escape
  for (let i = 0; i < 3; i++) {
    await key("escape");
    await sleep(300);
  }
  await sleep(300);
});

test("GlassMotion: morph 几何过渡 + scroll-edge + backdrop 亮度实测", async () => {
  await switchTo("glassmotion");
  await sleep(500);
  const before = (await query("story.glassmotion.morph"))[0]?.rect;
  assert(before, "morph 玻璃节点应存在");
  await clickTestId("story.glassmotion.morphbtn");
  await sleep(800); // 等 18 帧 morph 过渡完成
  const after = (await query("story.glassmotion.morph"))[0]?.rect;
  appendLog(`  morph rect: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
  assert(Math.abs(after.w - before.w) > 50, `morph 应显著改变宽度 (${before.w} -> ${after.w})`);
  await shot("glassmotion-morphed");

  // scroll-edge：程序化滚动后玻璃条出现边缘渐变。
  // 回归：Scroll +80 曾直接写 ScrollState.scroll_y（绕过 setScrollY），state 变了
  // 但 content 的 translate 没同步，内容纹丝不动 —— 只截图的旧用例看不出来。
  const rowBefore = findByText(await tree(), "Content row 2");
  assert(rowBefore, "Content row 2 应可见");
  await clickTestId("story.glassmotion.scrollbtn");
  await sleep(500);
  const rowAfter = findByText(await tree(), "Content row 2");
  appendLog(`  Scroll +80: Content row 2 y ${rowBefore.y} -> ${rowAfter?.y}`);
  assert(rowAfter && Math.abs(rowBefore.y - rowAfter.y - 80) < 1, `Scroll +80 应让内容上移 80px (${rowBefore.y} -> ${rowAfter?.y})`);
  await shot("glassmotion-scrolled");

  // backdrop 亮度自适应：玻璃在屏 → GPU luminance 回读应产出实测值
  const st = await stats();
  appendLog(`  backdrop_luminance_milli: ${st.backdrop_luminance_milli}`);
  // 逐区域亮度池化后（2026-08-02），全局值 = 页面全部 glass 区域的均值：
  // 白底滚动区玻璃 + 其余彩底玻璃混合，均值落在中间带。断言收敛为
  // "回读管线活着且值在物理合理区间"（-1000 = 回读管线未产出）。
  assert(st.backdrop_luminance_milli > 80 && st.backdrop_luminance_milli < 1000, `backdrop luminance 实测应在合理区间 (got ${st.backdrop_luminance_milli}‰)`);
  assert((await health()).status === "ok", "app died after glassmotion");
});

/// 灰度梯度能量：rect 内相邻像素亮度差的绝对值均值。锐利文字笔画贡献
/// 大量高频边缘，磨砂玻璃后的同一段文字被 blur 抹平 → 能量显著下降。
function gradientEnergy(pngPath: string, rect: { x: number; y: number; w: number; h: number }): number {
  const png = decodePng(pngPath);
  const s = png.width / 1100;
  const x0 = Math.round(rect.x * s), y0 = Math.round(rect.y * s);
  const x1 = Math.round((rect.x + rect.w) * s), y1 = Math.round((rect.y + rect.h) * s);
  const lum = (x: number, y: number) => {
    const i = (y * png.width + x) * png.channels;
    return 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
  };
  let e = 0, n = 0;
  for (let y = y0; y < y1 - 1; y++) {
    for (let x = x0; x < x1 - 1; x++) {
      const c = lum(x, y);
      e += Math.abs(lum(x + 1, y) - c) + Math.abs(lum(x, y + 1) - c);
      n++;
    }
  }
  return e / Math.max(n, 1);
}

test("GlassMotion: scroll-edge 玻璃条在任意滚动位置都持续模糊背后内容", async () => {
  // 回归（2026-09-29 用户报告）：真实滚轮滚动 scroll-edge 区块后，玻璃条
  // 下半截失去模糊，背后 "Content row N" 锐利透出、与玻璃条文字叠在一起。
  // 根因两层：GlassBox scroll-edge stops 从 1 渐到 0（把玻璃基底糊度削成
  // sharp）+ shader 把 BlurGradient.strength 当目标糊度（str>0.001 即整段生效）。
  // 判据：玻璃条区域梯度能量（高频细节）在各滚动位置都保持在未滚动基线附近，
  // 且远低于同宽的未遮挡内容带（锐利文字的能量参照）。
  await switchTo("glassmotion");
  await sleep(300);
  const bar = (await query("story.glassmotion.bar"))[0]?.rect;
  assert(bar, "scroll-edge 玻璃条节点应存在");
  const wheelX = bar.x + 200, wheelY = bar.y + 150;
  // 先回到顶部（前一个用例点过 Scroll +80）
  // 大步上滚会触发顶部回弹：等 "Content row 0" 回到视口顶部（回弹结束）
  await scrollAt(wheelX, wheelY, 0, 2000);
  await waitFor(async () => {
    const r0 = findByText(await tree(), "Content row 0");
    return r0 && Math.abs(r0.y - bar.y) < 1 ? r0 : null;
  }, 4000, 50);
  await sleep(400);
  // 玻璃条左半（覆盖 Content row 文字列），上下各内缩 4px 避开阴影/rim
  const glassBand = { x: bar.x + 4, y: bar.y + 4, w: 190, h: bar.h - 8 };
  // 参照带：玻璃条正下方同宽同高的未遮挡内容（阴影区外）
  const sharpBand = { x: bar.x + 4, y: bar.y + bar.h + 24, w: 190, h: bar.h - 8 };
  const base = `${DIR}/story-glassmotion-scroll-0.png`;
  await screenshot(base);
  const baseE = gradientEnergy(base, glassBand);
  appendLog(`  scroll 0: glass=${baseE.toFixed(2)} sharp=${gradientEnergy(base, sharpBand).toFixed(2)}`);
  // 小步（刚开始滚动，edge 强度爬升中）+ 中步 + 大步（满强度、深滚动位置）
  const steps = [6, 20, 40, 120, 300];
  let total = 0;
  for (const dy of steps) {
    total += dy;
    await scrollAt(wheelX, wheelY, 0, -dy);
    await sleep(450);
    const png = `${DIR}/story-glassmotion-scroll-${total}.png`;
    await screenshot(png);
    const g = gradientEnergy(png, glassBand);
    const sh = gradientEnergy(png, sharpBand);
    appendLog(`  scroll ${total}: glass=${g.toFixed(2)} sharp=${sh.toFixed(2)}`);
    assert(sh > 3, `参照带应是锐利文字（sharp=${sh.toFixed(2)}），否则判据失效`);
    assert(g < sh * 0.35, `滚动 ${total}px 后玻璃条背后文字未被模糊: glass=${g.toFixed(2)} vs sharp=${sh.toFixed(2)}`);
    assert(g < baseE + 1.0, `滚动 ${total}px 后玻璃条高频细节显著上升（blur 失效）: ${g.toFixed(2)} vs 未滚动 ${baseE.toFixed(2)}`);
  }
  assert((await health()).status === "ok", "app died after glassmotion scroll");
});

test("GlassChrome: Scroll ±90 按钮真的滚动画布（经 setScrollY，边界 clamp）", async () => {
  // 回归：按钮回调曾直接写 ScrollState.scroll_y，画布不动。
  await switchTo("glasschrome");
  await sleep(400);
  const y = async () => (await query("story.glasschrome.canvas"))[0]?.rect.y;
  const y0 = await y();
  assert(y0 !== undefined, "story.glasschrome.canvas 应存在");
  await clickTestId("story.glasschrome.scrolldown");
  await sleep(400);
  const y1 = await y();
  appendLog(`  Scroll +90: canvas y ${y0} -> ${y1}`);
  assert(y1 !== undefined && Math.abs(y0 - y1 - 90) < 1, `Scroll +90 应让画布上移 90px (${y0} -> ${y1})`);
  // 回到顶部后再上滚：clamp 在 0，不越界
  await clickTestId("story.glasschrome.scrollup");
  await sleep(400);
  await clickTestId("story.glasschrome.scrollup");
  await sleep(400);
  const y2 = await y();
  assert(y2 !== undefined && Math.abs(y2 - y0) < 1, `Scroll −90 两次应停在顶部 (${y0} vs ${y2})`);
  assert((await health()).status === "ok", "app died after glasschrome scroll");
});

test("GlassEdge: 贴窗口边缘的 glass 无黑边", async () => {
  // 回归：capture pad 超出窗口 RT 被清成透明黑，glass shader 若不按
  // coverage 归一化，贴边 panel 会晕出一圈黑（画布 app 左右 panel 实拍）。
  await switchTo("glassedge");
  const left = (await query("story.glassedge.left"))[0]?.rect;
  const right = (await query("story.glassedge.right"))[0]?.rect;
  assert(left && right, "左右贴边玻璃 panel 应存在");
  // panel 必须真的贴住窗口左右边缘，否则测不到 pad 越界路径
  assert(left.x <= 1, `left panel 应贴窗口左边缘 (x=${left.x})`);
  appendLog(`  panels: left=${JSON.stringify(left)} right=${JSON.stringify(right)}`);
  await sleep(400); // 等 glass 合成稳定
  const png = `${DIR}/story-glassedge.png`;
  await shot("glassedge");
  // 采窗口极边缘的细条（避开顶部 traffic lights / 底部 panel 圆角）：
  // 黑边 bug 下这里最深像素接近纯黑（sum < 150）；正常磨砂是亮色延展。
  const strips: [string, { x: number; y: number; w: number; h: number }][] = [
    ["left-edge", { x: left.x + 1, y: left.y + 60, w: 4, h: left.h - 120 }],
    ["right-edge", { x: right.x + right.w - 5, y: right.y + 60, w: 4, h: right.h - 120 }],
    ["left-top-edge", { x: left.x + 30, y: left.y + 1, w: left.w - 60, h: 4 }],
    ["left-bottom-edge", { x: left.x + 30, y: left.y + left.h - 5, w: left.w - 60, h: 4 }],
  ];
  for (const [label, rect] of strips) {
    const [r, g, b] = darkestPixel(png, rect);
    appendLog(`  ${label}: darkest=(${r},${g},${b})`);
    assert(r + g + b > 330, `${label} 出现黑边 fringe: darkest=(${r},${g},${b})`);
  }
  assert((await health()).status === "ok", "app died after glassedge");
});

test("GlassIslands: 同帧两个 blur+rounded_clip 岛都必须显示内容", async () => {
  // 回归（下游回归）：blur + overflow_hidden + corner_radius 同节点时，
  // rounded_clip surface 期望 owner-local 内容帧，而 lowering 早先只对
  // opacity layer 投影 → 内容以 world 坐标画出纹理外 → 岛内容全丢只剩玻璃壳。
  await switchTo("glassislands");
  await sleep(500); // 等 glass 合成稳定
  const png = `${DIR}/story-glassislands.png`;
  await shot("glassislands");
  for (const name of ["first", "second"]) {
    const slab = (await query(`story.glassislands.${name}.slab`))[0]?.rect;
    assert(slab, `${name} 岛的深色内容块节点应存在`);
    const inner = { x: slab.x + 10, y: slab.y + 10, w: slab.w - 20, h: slab.h - 20 };
    // 内容块是近黑色 (24,28,40)：丢失时这里是白玻璃底，暗像素≈0
    assertRegionHasInk(png, inner, `${name} 岛内容块像素`, 5000);
  }
  // gi=0 "仅 blur" 合同：first 岛左缘 8px 带压在近黑竖条上（story 里的 rim_probe），
  // rim_sharp 若漏 gi 门控，黑条会在边缘带清晰透出 → darkest 接近纯黑。
  // 正常 blur-only 下黑条与亮色渐变糊成中灰。
  const first = (await query("story.glassislands.first"))[0]?.rect;
  assert(first, "first 岛 rect 应存在");
  // 差分断言：绝对阈值受主题/背景漂移影响（alpha 96 时代 sharp/blur 只差 30
  // 灰阶，抓不住变异）。参照带取岛内侧 inset 11..15px——同在黑条上但已出
  // rim_sharp 8px 带、恒为 blur。rim 带明显暗于参照带 = sharp 回退漏出。
  const rimBand = { x: first.x + 1, y: first.y + 40, w: 5, h: first.h - 80 };
  const refBand = { x: first.x + 11, y: first.y + 40, w: 4, h: first.h - 80 };
  const [rr, rg, rb] = darkestPixel(png, rimBand);
  const [fr, fg, fb] = darkestPixel(png, refBand);
  const rimSum = rr + rg + rb, refSum = fr + fg + fb;
  appendLog(`  rim-band darkest=(${rr},${rg},${rb}) ref-band darkest=(${fr},${fg},${fb})`);
  assert(rimSum > refSum - 90, `gi=0 岛边缘出现 sharp 回退带: rim=${rimSum} ref=${refSum}`);
  assert((await health()).status === "ok", "app died after glassislands");
});

test("DropdownMenu: 交互 — 点开显示 items", async () => {
  await switchTo("dropdown");
  const pos = await screenPos("story.dropdown.trigger");
  await clickAt(pos.x + 30, pos.y + 12);
  await sleep(350);
  await shot("dropdown-open");
  // 同 Menu：portal 化后菜单项在窗口根，从整棵树收文本
  const root = await tree();
  const out: string[] = [];
  collectText(root, out);
  const joined = out.join(" │ ");
  appendLog(`  dropdown opened, texts: ${joined}`);
  for (const item of ["New File", "Save"]) {
    assert(joined.includes(item), `dropdown 打开后缺 item "${item}" — 实际: ${joined}`);
  }
});

test("CanvasEvents: scroll 修饰键 + magnify + drag + 剪贴板 PNG 回环", async () => {
  await switchTo("canvasevents");
  await sleep(300);
  const canvas = await screenPos("story.canvasevents.canvas");
  const cxp = canvas.x + 100;
  const cyp = canvas.y + 60;

  // scroll 带 Cmd 修饰键 → on_scroll 收到 modifiers
  await scrollAt(cxp, cyp, 0, -12, { cmd: true });
  await sleep(200);
  let texts: string[] = [];
  collectText((await query("story.canvasevents.scroll"))[0], texts);
  appendLog(`  scroll label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("cmd=true"), `on_scroll 应收到 cmd 修饰键 (got: ${texts.join(" ")})`);

  // magnify began→changed→ended
  await magnifyAt(cxp, cyp, 0, 0);
  await magnifyAt(cxp, cyp, 0.25, 1);
  await magnifyAt(cxp, cyp, 0.25, 1);
  await magnifyAt(cxp, cyp, 0, 2);
  await sleep(200);
  texts = [];
  collectText((await query("story.canvasevents.magnify"))[0], texts);
  appendLog(`  magnify label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("accum=0.50"), `magnify 应累计 0.50 (got: ${texts.join(" ")})`);
  assert(texts.join(" ").includes("phase=ended"), `magnify 最后 phase 应为 ended (got: ${texts.join(" ")})`);

  // drag entered → dropped 带路径
  await dragAt(cxp, cyp, 0);
  await dragAt(cxp, cyp, 3, "/tmp/fake-image.png");
  await sleep(200);
  texts = [];
  collectText((await query("story.canvasevents.drag"))[0], texts);
  appendLog(`  drag label: ${texts.join(" ")}`);
  assert(texts.join(" ").includes("dropped"), `drag 应收到 dropped (got: ${texts.join(" ")})`);
  assert(texts.join(" ").includes("/tmp/fake-image.png"), `dropped 应携带路径 (got: ${texts.join(" ")})`);

  // 剪贴板 PNG 回环：写 2x2 红 PNG → probe/count/read 全链路
  await clickTestId("story.canvasevents.clipbtn");
  await sleep(400);
  texts = [];
  collectText((await query("story.canvasevents.clip"))[0], texts);
  appendLog(`  clip label: ${texts.join(" ")}`);
  const clip = texts.join(" ");
  assert(clip.includes("image=true"), `probe 应报告 image (got: ${clip})`);
  assert(clip.includes("2x2"), `应读回 2x2 图片 (got: ${clip})`);
  assert(clip.includes("px_ok=true"), `像素应为纯红 premultiplied (got: ${clip})`);
  await shot("canvasevents");
  assert((await health()).status === "ok", "app died after canvasevents");
});

// ── 彩色 emoji 像素验收 ──
//
// 这是整条彩色字形管线唯一有力的验证：灰度管线也能把 emoji 画出**形状**
// （覆盖率掩码 × 文字色），只是丢了颜色。所以不能断言"画出来了"，必须断言
// **三通道不相等** —— 灰度输出的 R/G/B 必然相等（同一个 alpha 乘同一个
// 中性灰文字色），三通道分离只可能来自真正的 BGRA 采样。
//
// 靶子是纯色方块 emoji：中心整块同色，不受字号/抗锯齿/中心点取样偏移影响。
test("Emoji: 像素 — 中心像素三通道不相等（证明是彩色而非灰度）", async () => {
  await switchTo("emoji");
  // switchTo 只等"面板出现任意文本"，靶子节点可能晚一拍才布局出来
  // （emoji 是最后一个 nav 项，切换时 ScrollArea 还在滚）。显式等它就位。
  await waitFor(async () => {
    const q = await query("story.emoji.red");
    return q.length > 0 && q[0].rect.w > 10 ? q : null;
  }, 6000, 60);
  await sleep(500); // settle：等字形进 atlas + 首帧稳定
  await shot("emoji-color");
  const png = `${DIR}/story-emoji-color.png`;

  // [test_id, 主导通道] —— 除了三通道不等，还断言主导通道正确，
  // 排除"通道顺序搞反了（BGRA 当成 RGBA）"这种恰好也三通道不等的错误。
  const cases: Array<[string, 0 | 1 | 2, string]> = [
    ["story.emoji.red", 0, "red"],
    ["story.emoji.green", 1, "green"],
    ["story.emoji.blue", 2, "blue"],
  ];

  for (const [id, dominant, name] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    const px = centerPixel(png, nodes[0].rect);
    const [r, g, b] = px;
    const spread = Math.max(r, g, b) - Math.min(r, g, b);
    appendLog(`  ${id}: rgb=(${r},${g},${b}) spread=${spread} dominant_expect=${name}`);

    // 核心断言：三通道不相等。灰度管线在这里必然 spread=0。
    assert(
      spread > 40,
      `${id} 中心像素三通道过于接近 rgb=(${r},${g},${b}) spread=${spread} — ` +
        `说明 emoji 仍走灰度路径（灰度必然三通道相等）`,
    );

    // 主导通道断言：防 BGRA/RGBA 通道顺序写反。
    const maxIdx = px.indexOf(Math.max(r, g, b));
    assert(
      maxIdx === dominant,
      `${id} 主导通道应为 ${name}（索引${dominant}），实际 rgb=(${r},${g},${b}) ` +
        `主导索引=${maxIdx} — 疑似 BGRA/RGBA 通道顺序写反`,
    );
  }

  // 对照组：普通文本在同样的中性灰文字色下必须**仍是灰度**（三通道近似相等）。
  // 若这里也三通道分离，说明彩色分支误伤了灰度路径。
  //
  // 不能取中心像素 —— "AAAA" 的几何中心落在字母之间的背景上，那样测的是
  // 背景不是字形。这里扫整个 rect 找最深的像素（必然是笔画内部），断言它是灰的。
  const ctrl = await query("story.emoji.control");
  assert(ctrl.length > 0 && ctrl[0].rect.w > 10, "story.emoji.control 节点没布局出来");
  const cpx = darkestPixel(png, ctrl[0].rect);
  const cspread = Math.max(...cpx) - Math.min(...cpx);
  appendLog(`  story.emoji.control darkest: rgb=(${cpx.join(",")}) spread=${cspread}`);
  // 必须真的采到了笔画（灰字 rgb≈128），否则这条断言等于没测。
  assert(
    Math.max(...cpx) < 200,
    `灰度对照组没采到笔画像素 rgb=(${cpx.join(",")}) — 文字没画出来？`,
  );
  assert(
    cspread <= 8,
    `灰度对照组 rgb=(${cpx.join(",")}) spread=${cspread} 不再是灰度 — 彩色分支误伤了灰度路径`,
  );

  assert((await health()).status === "ok", "app died after emoji story");
});

// ── RTL 双向文本像素验收 ──
//
// 文本节点即使把字形**反向重叠**堆在一起，query 出来的字符串和 rect 也
// 完全正常 —— 只有像素能区分对错。判据是**墨迹的水平分布**：
//
//   正确：N 个字形沿 pen 依次铺开，墨迹跨度接近节点宽度。
//   错误：RTL 被切碎/反向定位，字形挤成一坨，墨迹跨度大幅塌缩。
//
// 具体到本仓库的历史 bug：segmentText 曾把每个阿拉伯/希伯来码点切成
// 独立段分别 shape，bidi 重排和阿拉伯连写全毁。
test("RTL: 像素 — 墨迹水平铺开（证明未反向重叠/未逐码点切碎）", async () => {
  await switchTo("rtl");
  await waitFor(async () => {
    const q = await query("story.rtl.arabic");
    return q.length > 0 && q[0].rect.w > 10 ? q : null;
  }, 6000, 60);
  await sleep(500); // settle：等字形进 atlas + 首帧稳定
  await shot("rtl-bidi");
  const png = `${DIR}/story-rtl-bidi.png`;

  // 注意：文本节点在 column 里会被拉伸到整列宽，rect.w 远大于文字本身，
  // 所以**不能**拿 span/rect.w 当判据（LTR 对照组实测只有 0.156）。
  // 判据改为：墨迹跨度 vs **字号推算的期望文字宽度**。
  //
  // 期望宽度按 N 个字形 × 每字形约 0.5em 估；下面按各 case 的实际字号计算。
  // 这是保守下界：任何一款字体的平均字宽都远大于 0.35em，而字形若反向
  // 重叠堆在一起，跨度会塌到 1~2 个字形宽，必然打不到这个下界。
  // [test_id, 字形数（视觉上应铺开的字形个数）, 字号]
  const cases: Array<[string, number, number]> = [
    ["story.rtl.ltr_control", 5, 36], // abcde — 对照组，先验证判据成立
    ["story.rtl.arabic", 5, 36], // مرحبا
    ["story.rtl.hebrew", 4, 36], // שלום
    ["story.rtl.mixed", 9, 36], // ab + 5 阿拉伯 + cd
  ];

  for (const [id, glyphCount, fontPx] of cases) {
    const nodes = await query(id);
    assert(nodes.length > 0 && nodes[0].rect.w > 10, `${id} 节点没布局出来`);
    const ink = inkColumns(png, nodes[0].rect);
    // inkColumns 返回的是物理像素列；换算回逻辑像素再跟字号比。
    const scale = ink.width / nodes[0].rect.w;
    const spanLogical = ink.span / scale;
    const minPerGlyph = 0.35 * fontPx; // 保守下界
    const minExpected = glyphCount * minPerGlyph;
    const density = ink.cols / ink.span;
    appendLog(
      `  ${id} ink: first=${ink.first} last=${ink.last} span=${ink.span}px ` +
        `spanLogical=${spanLogical.toFixed(1)} minExpected=${minExpected.toFixed(1)} ` +
        `cols=${ink.cols} density=${density.toFixed(3)} centroid=${ink.centroid.toFixed(4)}`,
    );

    // 真的采到笔画了（否则下面的跨度断言等于没测）。
    assert(ink.cols > 0, `${id} 没采到任何墨迹 — 文字没画出来？`);

    // 核心断言：墨迹跨度必须够宽。字形反向重叠时跨度会塌到 1~2 个字形宽。
    assert(
      spanLogical >= minExpected,
      `${id} 墨迹跨度 ${spanLogical.toFixed(1)}px < 期望下界 ${minExpected.toFixed(1)}px` +
        `（${glyphCount} 字形 × ${minPerGlyph}px）— 字形疑似反向重叠或被逐码点切碎堆在一起`,
    );

    // 墨迹密度：排除"两端各一个字形、中间全空"这种恰好跨度达标、
    // 但中间字形其实都堆叠/缺失的情况。
    assert(
      density > 0.5,
      `${id} 墨迹密度 ${density.toFixed(3)}（cols=${ink.cols} / span=${ink.span}）过低 — ` +
        `中间字形疑似缺失或堆叠`,
    );
  }

  // ── 阿拉伯语连写（cursive joining）断言 ──
  //
  // 上面的跨度/密度判据抓不住本仓库真正的 failure mode：RTL 被逐码点
  // 切碎时，字形**依然均匀铺开**（每段各自推进 cursor），只是顺序反了、
  // 且每个字母退化成孤立形。跨度反而变**大**，密度也还行 —— 全测不出来。
  //
  // 真正的指纹是**连写**：阿拉伯语 "مرحبا" 的字母在正确 shaping 下彼此
  // 笔画相连，墨迹是**一条不断的横向连续区**（density = 1.000，零空隙）。
  // 一旦逐码点 shape，每个字母变成孤立形、字母间必然出现空白列。
  //
  // 实测：修复后 span=175px density=1.000；逐码点切碎时 span=218px
  // density=0.904。因此断言"零空隙"，这是连写唯一可能的结果。
  {
    const nodes = await query("story.rtl.arabic");
    const ink = inkColumns(png, nodes[0].rect);
    const density = ink.cols / ink.span;
    appendLog(`  story.rtl.arabic cursive-joining: density=${density.toFixed(4)} (需 = 1.0)`);
    assert(
      density >= 0.995,
      `阿拉伯语墨迹存在空隙 density=${density.toFixed(4)}（cols=${ink.cols} / span=${ink.span}）— ` +
        `字母未连写，说明 RTL 被逐码点切碎 shaping（每个字母退化成孤立形）`,
    );
    // 同时钉住连写后的紧凑宽度：孤立形排布会明显更宽。
    const scale = ink.width / nodes[0].rect.w;
    const spanLogical = ink.span / scale;
    appendLog(`  story.rtl.arabic cursive-width: spanLogical=${spanLogical.toFixed(1)} (需 < 82)`);
    assert(
      spanLogical < 82,
      `阿拉伯语墨迹跨度 ${spanLogical.toFixed(1)}px 过宽 — 连写形态比孤立形紧凑，` +
        `过宽说明退化成了孤立形（逐码点 shaping）`,
    );
  }

  // 复杂 bidi 输入首先钉住 story 数据本身，再以像素确认每个 case 都有足够
  // 水平墨迹。最终视觉顺序由同一张 golden 捕获。
  const complexCases: Array<[string, string]> = [
    ["story.rtl.numbers", "abc مرحبا 123 xyz"],
    ["story.rtl.mirrored_parens", "مرحبا (abc) שלום"],
    ["story.rtl.mirrored_brackets", "مرحبا [abc] שלום"],
    ["story.rtl.tashkeel", "مَرْحَبًا"],
    ["story.rtl.switches", "abc مرحبا xyz שלום 123"],
    ["story.rtl.symbols", "مرحبا https://example.com/a-b?q=1:2 test@example.com +12/34 - שלום"],
  ];
  for (const [id, expectedText] of complexCases) {
    const nodes = await query(id);
    assert(nodes.length > 0, `${id} 不存在`);
    assert(nodes[0].text === expectedText, `${id} 测试文本意外变化: ${JSON.stringify(nodes[0].text)}`);
    const ink = inkColumns(png, nodes[0].rect);
    appendLog(`  ${id} complex-bidi ink: span=${ink.span} cols=${ink.cols}`);
    assert(ink.cols >= 12 && ink.span >= 20, `${id} 没有形成可辨识的文字墨迹`);
  }

  // Tashkeel 是 combining marks，不应像独立字符一样增加推进宽度。
  const tashkeelBaseNode = (await query("story.rtl.tashkeel_base"))[0];
  const tashkeelNode = (await query("story.rtl.tashkeel"))[0];
  const baseInk = inkColumns(png, tashkeelBaseNode.rect);
  const markedInk = inkColumns(png, tashkeelNode.rect);
  const tashkeelRatio = markedInk.span / baseInk.span;
  appendLog(`  tashkeel advance ratio=${tashkeelRatio.toFixed(3)} (${markedInk.span}/${baseInk.span})`);
  assert(
    tashkeelRatio >= 0.8 && tashkeelRatio <= 1.25,
    `tashkeel 把 combining mark 当成独立 advance：宽度比=${tashkeelRatio.toFixed(3)}`,
  );

  assert((await health()).status === "ok", "app died after rtl story");
});

test("RTL: 窄宽换行的 caret、selection rect 与 hit-testing 共用视觉坐标", async () => {
  await switchTo("rtl");
  const rect = await screenPos("story.rtl.editor");
  await sleep(300);

  const initial = await inputState("story.rtl.editor");
  assert((initial.display_line_count ?? 0) >= 2, `RTL 编辑器没有触发 soft wrap: ${initial.display_line_count}`);

  const graphemeBoundaries = new Set<number>([0]);
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const encoder = new TextEncoder();
  for (const part of segmenter.segment(initial.buffer)) {
    graphemeBoundaries.add(encoder.encode(initial.buffer.slice(0, part.index)).length);
  }
  graphemeBoundaries.add(initial.buffer_len);

  const clickAndRead = async (x: number, y: number) => {
    await clickAt(x, y);
    await sleep(120);
    const state = await inputState("story.rtl.editor");
    assert(graphemeBoundaries.has(state.cursor_pos), `hit-test 落在 grapheme 内部: byte=${state.cursor_pos}`);
    assert(state.cursor_rect != null && state.cursor_rect.h > 0, `click (${x},${y}) 后没有 caret rect`);
    const caret = state.cursor_rect!;
    assert(Math.abs(caret.x - x) <= 28, `caret x=${caret.x} 与点击 x=${x} 不一致`);
    assert(Math.abs(caret.y + caret.h / 2 - y) <= 12, `caret y=${caret.y} 与点击 y=${y} 不在同一视觉行`);
    return state;
  };

  // 同一 RTL 视觉行左右两侧，以及 soft-wrap 后的下一视觉行。
  const left = await clickAndRead(rect.x + rect.w * 0.28, rect.y + 10);
  const right = await clickAndRead(rect.x + rect.w * 0.72, rect.y + 10);
  const wrapped = await clickAndRead(rect.x + rect.w * 0.38, rect.y + 30);
  assert(left.cursor_pos !== right.cursor_pos, "同一 RTL 行左右 hit-test 映射到了同一逻辑位置");
  assert(left.cursor_rect!.x < right.cursor_rect!.x, "caret rect 的视觉 x 顺序与点击方向相反");
  assert(wrapped.cursor_rect!.y > left.cursor_rect!.y + 8, "soft-wrap 后行首/行尾仍映射到上一视觉行");

  // 跨两条视觉行拖选；选区可能因 bidi run 被拆成多个不连续 rect。
  const dragStart = { x: rect.x + rect.w * 0.24, y: rect.y + 10 };
  const dragEnd = { x: rect.x + rect.w * 0.76, y: rect.y + 30 };
  await mouseDown(dragStart.x, dragStart.y);
  await mouseMove((dragStart.x + dragEnd.x) / 2, (dragStart.y + dragEnd.y) / 2);
  await mouseMove(dragEnd.x, dragEnd.y);
  await mouseUp(dragEnd.x, dragEnd.y);
  await sleep(180);

  const selected = await inputState("story.rtl.editor");
  assert((selected.anchor ?? -1) >= 0, "RTL drag 没有建立 selection anchor");
  assert(selected.anchor !== selected.cursor_pos, "RTL drag 的 selection 为空");
  const selectionRects = selected.selection_rects ?? [];
  assert(selectionRects.length >= 2, `跨行 bidi selection rect 数量不足: ${selectionRects.length}`);
  for (const selection of selectionRects) {
    assert(selection.w > 0 && selection.h > 0, `空 selection rect: ${JSON.stringify(selection)}`);
    assert(
      selection.x >= rect.x - 2 && selection.x + selection.w <= rect.x + rect.w + 2 &&
        selection.y >= rect.y - 2 && selection.y + selection.h <= rect.y + rect.h + 2,
      `selection rect 越出编辑器: ${JSON.stringify(selection)} vs ${JSON.stringify(rect)}`,
    );
  }

  await shot("rtl-bidi-interaction");
  assert((await health()).status === "ok", "app died after RTL interaction test");
});

// ══════════════════════════════════════════════════════════════════════
// IME (CJK marked text) 覆盖
//
// 背景：IME 实现（events.zig / event_dispatcher.zig / input/state.zig /
// input/textarea.zig / editable_block.zig）与 e2e harness RPC（/ime_preedit
// /ime_commit）都早已存在，但**零测试用例使用**。这一组补上覆盖。
//
// 双重验证：
//   - log 数据值 —— inputState() 读组件内部 state（buffer / cursor_pos /
//     ime_preedit_len / ime_phase），确认状态机对；
//   - 视觉 —— query() 收集渲染树文本，确认 marked text 真的**上屏**
//     （buildDisplayText 会把 preedit 插进 cursor 处），外加 screenshot。
//
// 已知缺口（ROADMAP「已知不支持」，撞到不修，只记录）：
//   字素簇（emoji 退格/组合字符）、RTL 编辑交互。下面的用例刻意只用 CJK。
// ══════════════════════════════════════════════════════════════════════

/// 读某个 input/textarea 渲染出的可见文本（拼接子树全部 text 节点）。
async function visibleText(testId: string): Promise<string> {
  const q = await query(testId);
  const out: string[] = [];
  if (q[0]) collectText(q[0], out);
  return out.join("");
}

/// 找 input 子树里的 caret 节点（宽 1px 的竖条），返回其 x。找不到返回 -1。
function findCaretRect(node: any): any {
  if (node?.rect && node.rect.w === 1 && node.rect.h > 0) return node;
  for (const c of node?.children ?? []) {
    const r = findCaretRect(c);
    if (r) return r;
  }
  return null;
}

async function caretXOf(testId: string): Promise<number> {
  const q = await query(testId);
  const c = q[0] ? findCaretRect(q[0]) : null;
  return c ? c.rect.x : -1;
}

/// 清空 Input：聚焦 → 全选 → 删除，并断言真的空了。
async function clearInput(testId: string): Promise<void> {
  await clickTestId(testId);
  await sleep(150);
  await key("a", { cmd: true });
  await sleep(80);
  await key("backspace");
  await sleep(80);
  for (let i = 0; i < 24; i++) await key("backspace");
  await sleep(150);
  const s = await inputState(testId);
  assert(s.buffer_len === 0, `clear ${testId} 失败: buffer_len=${s.buffer_len} buffer="${s.buffer}"`);
}

test("IME: Input preedit 显示 —— marked text 未上屏但可见，buffer 不变", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  // 先落一段已提交文本作为"上下文"，preedit 应插在 cursor 处而非末尾。
  await imeCommit("你好");
  await sleep(150);
  const base = await inputState("story.input.name");
  appendLog(`  [preedit] base: buffer="${base.buffer}" len=${base.buffer_len} cursor=${base.cursor_pos} phase=${base.ime_phase}`);
  assert(base.buffer_len === 6, `基线 buffer_len 应为 6（2 CJK×3B），got ${base.buffer_len}`);

  // 拼音输入过程：逐步 preedit（模拟 "shi" → "世界" 候选）
  await imePreedit("shi", 3);
  await sleep(120);
  const p1 = await inputState("story.input.name");
  appendLog(`  [preedit] "shi": buffer="${p1.buffer}" len=${p1.buffer_len} preedit_len=${p1.ime_preedit_len} phase=${p1.ime_phase}`);
  // 核心断言 1：preedit **不进 buffer**（未上屏）
  assert(p1.buffer_len === 6, `preedit 期间 buffer 被污染: len=${p1.buffer_len} buffer="${p1.buffer}"`);
  assert(p1.ime_preedit_len === 3, `ime_preedit_len 应为 3，got ${p1.ime_preedit_len}`);
  assert(p1.ime_phase === "composing", `ime_phase 应为 composing，got "${p1.ime_phase}"`);

  // 核心断言 2：marked text 真的**渲染出来**（视觉侧）
  const vis1 = await visibleText("story.input.name");
  appendLog(`  [preedit] visible text: "${vis1}"`);
  assert(vis1.includes("你好shi"), `渲染文本未含 marked text "shi"（应插在 cursor 处）— 实际: "${vis1}"`);

  // 候选切换：preedit 内容替换（"shi" → "世界"），不应叠加
  await imePreedit("世界", 6);
  await sleep(120);
  const p2 = await inputState("story.input.name");
  appendLog(`  [preedit] "世界": buffer="${p2.buffer}" len=${p2.buffer_len} preedit_len=${p2.ime_preedit_len}`);
  assert(p2.buffer_len === 6, `候选切换后 buffer 被污染: len=${p2.buffer_len}`);
  assert(p2.ime_preedit_len === 6, `替换后 preedit_len 应为 6（不是叠加的 9），got ${p2.ime_preedit_len}`);
  const vis2 = await visibleText("story.input.name");
  appendLog(`  [preedit] visible text: "${vis2}"`);
  assert(vis2.includes("你好世界"), `候选替换后渲染文本错误 — 实际: "${vis2}"`);
  assert(!vis2.includes("shi"), `旧 preedit "shi" 残留在渲染文本里 — 实际: "${vis2}"`);

  const size = await shot("ime-input-preedit");
  assert(size > 3000, `preedit 截图过小 (${size} bytes)`);

  // 收尾：取消，别污染后续用例
  await imePreedit("", 0);
  await sleep(100);
});

test("IME: Input commit —— 确认后文本落入 buffer，preedit 清空", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  await imePreedit("zhong", 5);
  await sleep(120);
  const pre = await inputState("story.input.name");
  assert(pre.buffer_len === 0 && pre.ime_preedit_len === 5, `commit 前状态异常: ${JSON.stringify(pre)}`);

  await imeCommit("中文");
  await sleep(180);
  const post = await inputState("story.input.name");
  appendLog(`  [commit] buffer="${post.buffer}" len=${post.buffer_len} cursor=${post.cursor_pos} preedit_len=${post.ime_preedit_len} phase=${post.ime_phase}`);
  assert(post.buffer === "中文", `commit 后 buffer 应为 "中文"，got "${post.buffer}"`);
  assert(post.buffer_len === 6, `commit 后 buffer_len 应为 6，got ${post.buffer_len}`);
  assert(post.cursor_pos === 6, `commit 后 cursor 应在末尾 6，got ${post.cursor_pos}`);
  assert(post.ime_preedit_len === 0, `commit 后 preedit 未清空: ${post.ime_preedit_len}`);
  assert(post.ime_phase !== "composing", `commit 后仍在 composing`);

  const vis = await visibleText("story.input.name");
  appendLog(`  [commit] visible text: "${vis}"`);
  assert(vis.includes("中文"), `commit 后渲染文本缺 "中文" — 实际: "${vis}"`);
  assert(!vis.includes("zhong"), `commit 后旧 preedit "zhong" 残留 — 实际: "${vis}"`);

  await shot("ime-input-commit");
});

test("IME: Input preedit 期间光标位置 —— caret 落在 preedit 内的 cursor_utf8_offset 处", async () => {
  await switchTo("input");
  await clearInput("story.input.name");

  // 基线：无 preedit 时 caret X
  await imeCommit("ab");
  await sleep(150);
  const caretBase = await caretXOf("story.input.name");
  appendLog(`  [caret] base "ab": caret_x=${caretBase.toFixed(2)}`);
  assert(caretBase > 0, `基线 caret 未找到 (x=${caretBase})`);

  // preedit "cde"，光标在 preedit 内部偏移 0 —— caret 不应右移
  await imePreedit("cde", 0);
  await sleep(150);
  const caret0 = await caretXOf("story.input.name");
  appendLog(`  [caret] preedit "cde" offset=0: caret_x=${caret0.toFixed(2)} (base=${caretBase.toFixed(2)})`);
  assert(
    Math.abs(caret0 - caretBase) < 1.5,
    `preedit cursor_offset=0 时 caret 应停在 preedit 起点 ${caretBase.toFixed(2)}，实际 ${caret0.toFixed(2)}`,
  );

  // 光标推到 preedit 末尾（offset=3）—— caret 应右移约 3 个字符宽
  await imePreedit("cde", 3);
  await sleep(150);
  const caret3 = await caretXOf("story.input.name");
  const dx = caret3 - caretBase;
  appendLog(`  [caret] preedit "cde" offset=3: caret_x=${caret3.toFixed(2)} Δ=${dx.toFixed(2)}px`);
  assert(dx > 8, `preedit cursor_offset=3 时 caret 应右移过 3 个字符（Δ>8px），实际 Δ=${dx.toFixed(2)}px`);

  // 中间位置（offset=1）应严格落在两者之间 —— 钉住"caret 随 offset 单调推进"
  await imePreedit("cde", 1);
  await sleep(150);
  const caret1 = await caretXOf("story.input.name");
  appendLog(`  [caret] preedit "cde" offset=1: caret_x=${caret1.toFixed(2)}`);
  assert(
    caret1 > caretBase + 1 && caret1 < caret3 - 1,
    `preedit cursor_offset=1 的 caret 应严格位于 offset=0 (${caretBase.toFixed(2)}) 与 offset=3 (${caret3.toFixed(2)}) 之间，实际 ${caret1.toFixed(2)}`,
  );

  await shot("ime-input-preedit-caret");
  await imePreedit("", 0);
  await sleep(100);
});

test("IME: Input preedit 取消 —— 空 preedit / 切走焦点都不留脏文本", async () => {
  await switchTo("input");
  await clearInput("story.input.name");
  await imeCommit("原文");
  await sleep(150);

  // ① 空 preedit（等价于 IME 撤销合成）
  await imePreedit("pinyin", 6);
  await sleep(120);
  assert((await inputState("story.input.name")).ime_preedit_len === 6, "preedit 未建立");
  await imePreedit("", 0);
  await sleep(150);
  const c1 = await inputState("story.input.name");
  appendLog(`  [cancel:empty] buffer="${c1.buffer}" len=${c1.buffer_len} preedit_len=${c1.ime_preedit_len} phase=${c1.ime_phase}`);
  assert(c1.ime_preedit_len === 0, `空 preedit 后未清空: ${c1.ime_preedit_len}`);
  assert(c1.ime_phase === "idle", `空 preedit 后 phase 应回 idle，got "${c1.ime_phase}"`);
  assert(c1.buffer === "原文", `取消后 buffer 被污染: "${c1.buffer}"`);
  const vis1 = await visibleText("story.input.name");
  assert(!vis1.includes("pinyin"), `取消后 marked text "pinyin" 仍在渲染文本里 — 实际: "${vis1}"`);

  // ② 切走焦点（on_blur → cancelImeComposition + discardIme）
  await imePreedit("canceled", 8);
  await sleep(120);
  assert((await inputState("story.input.name")).ime_preedit_len === 8, "第二段 preedit 未建立");
  await clickAt(900, 500); // 点面板空白区，让 Input 失焦
  await sleep(250);
  const c2 = await inputState("story.input.name");
  appendLog(`  [cancel:blur] buffer="${c2.buffer}" len=${c2.buffer_len} preedit_len=${c2.ime_preedit_len} phase=${c2.ime_phase}`);
  assert(c2.ime_preedit_len === 0, `失焦后 preedit 未清空: ${c2.ime_preedit_len}（脏 marked text 残留）`);
  assert(c2.ime_phase === "idle", `失焦后 phase 应回 idle，got "${c2.ime_phase}"`);
  assert(c2.buffer === "原文", `失焦后 buffer 被污染: "${c2.buffer}"（未上屏文本被误提交）`);
  const vis2 = await visibleText("story.input.name");
  appendLog(`  [cancel:blur] visible text: "${vis2}"`);
  assert(!vis2.includes("canceled"), `失焦后 marked text 仍在渲染文本里 — 实际: "${vis2}"`);

  await shot("ime-input-cancel");
});

test("IME: Textarea 多行 —— 换行边界处 preedit/commit 正确", async () => {
  await switchTo("textarea");
  await clickTestId("story.textarea.box");
  await sleep(200);
  // 清空
  await key("a", { cmd: true }); await sleep(80);
  await key("backspace"); await sleep(120);
  for (let i = 0; i < 24; i++) await key("backspace");
  await sleep(150);

  // 建两行："第一行\n" 然后在第二行上合成 —— 换行符是易错边界
  await imeCommit("第一行");
  await sleep(150);
  await key("enter");
  await sleep(150);
  const base = await inputState("story.textarea.box");
  appendLog(`  [ta] base: buffer=${JSON.stringify(base.buffer)} len=${base.buffer_len} cursor=${base.cursor_pos}`);
  assert(base.buffer.includes("\n"), `换行未插入: ${JSON.stringify(base.buffer)}`);
  const baseLen = base.buffer_len;
  const baseCursor = base.cursor_pos;

  // 第二行起始处 preedit
  await imePreedit("di er", 5);
  await sleep(150);
  const p = await inputState("story.textarea.box");
  appendLog(`  [ta] preedit: buffer=${JSON.stringify(p.buffer)} len=${p.buffer_len} preedit_len=${p.ime_preedit_len} phase=${p.ime_phase} cursor=${p.cursor_pos}`);
  assert(p.buffer_len === baseLen, `Textarea preedit 污染了 doc: ${baseLen} → ${p.buffer_len}`);
  assert(p.ime_preedit_len === 5, `Textarea preedit_len 应为 5，got ${p.ime_preedit_len}`);
  assert(p.ime_phase === "composing", `Textarea phase 应为 composing，got "${p.ime_phase}"`);
  assert(p.cursor_pos === baseCursor, `preedit 期间 doc cursor 不应移动: ${baseCursor} → ${p.cursor_pos}`);
  const visP = await visibleText("story.textarea.box");
  appendLog(`  [ta] visible during preedit: ${JSON.stringify(visP)}`);
  assert(visP.includes("di er"), `Textarea marked text 未渲染 — 实际: ${JSON.stringify(visP)}`);
  await shot("ime-textarea-preedit");

  // commit：落在第二行，第一行 + 换行符必须完好
  await imeCommit("第二行");
  await sleep(200);
  const c = await inputState("story.textarea.box");
  appendLog(`  [ta] commit: buffer=${JSON.stringify(c.buffer)} len=${c.buffer_len} cursor=${c.cursor_pos} preedit_len=${c.ime_preedit_len}`);
  assert(c.ime_preedit_len === 0, `Textarea commit 后 preedit 未清空: ${c.ime_preedit_len}`);
  assert(c.buffer === "第一行\n第二行", `Textarea 换行边界 commit 结果错误: ${JSON.stringify(c.buffer)}`);
  assert(c.cursor_pos === c.buffer_len, `Textarea commit 后 cursor 应在末尾 ${c.buffer_len}，got ${c.cursor_pos}`);
  const visC = await visibleText("story.textarea.box");
  appendLog(`  [ta] visible after commit: ${JSON.stringify(visC)}`);
  assert(visC.includes("第二行"), `Textarea commit 后渲染缺 "第二行" — 实际: ${JSON.stringify(visC)}`);
  assert(!visC.includes("di er"), `Textarea commit 后旧 preedit 残留 — 实际: ${JSON.stringify(visC)}`);

  await shot("ime-textarea-commit");
  assert((await health()).status === "ok", "app died after textarea IME");
});

test("IME: Textarea 取消 —— 失焦不把 marked text 写进 doc", async () => {
  await switchTo("textarea");
  await clickTestId("story.textarea.box");
  await sleep(200);
  const before = await inputState("story.textarea.box");
  appendLog(`  [ta:cancel] before: buffer=${JSON.stringify(before.buffer)} len=${before.buffer_len}`);

  await imePreedit("wo yao qu xiao", 14);
  await sleep(150);
  assert((await inputState("story.textarea.box")).ime_preedit_len === 14, "Textarea preedit 未建立");

  await clickAt(950, 520); // 点面板空白 → blur
  await sleep(300);
  const after = await inputState("story.textarea.box");
  appendLog(`  [ta:cancel] after blur: buffer=${JSON.stringify(after.buffer)} len=${after.buffer_len} preedit_len=${after.ime_preedit_len} phase=${after.ime_phase}`);
  assert(after.ime_preedit_len === 0, `Textarea 失焦后 preedit 未清空: ${after.ime_preedit_len}`);
  assert(after.ime_phase === "idle", `Textarea 失焦后 phase 应为 idle，got "${after.ime_phase}"`);
  assert(
    after.buffer === before.buffer,
    `Textarea 失焦后 doc 被 marked text 污染: ${JSON.stringify(before.buffer)} → ${JSON.stringify(after.buffer)}`,
  );
  const vis = await visibleText("story.textarea.box");
  assert(!vis.includes("wo yao qu xiao"), `Textarea 失焦后 marked text 仍在渲染文本 — 实际: ${JSON.stringify(vis)}`);

  await shot("ime-textarea-cancel");
});

// ═══════════════════════════════════════════════════════════════════════════
// CORE_REVIEW_2026-08-16 修复批次回归锚（story + e2e 双重验证）
// ═══════════════════════════════════════════════════════════════════════════

/// 读某 test_id 节点自身的 text（不含子树）。
async function labelText(id: string): Promise<string> {
  const q = await query(id);
  return q[0]?.text ?? "";
}

test("WordNav: Alt+←/→ 词跳 + 双击选词（希腊/西里尔/家庭 emoji 簇字节偏移）", async () => {
  // Batch A2 回归：修复前 2 字节 lead 落进 ASCII 路径 → Alt+词跳原地卡死、
  // 双击选出空范围。字节账本见 stories.zig WORDNAV_TEXT 注释。
  await switchTo("wordnav");
  const TA = "story.wordnav.ta";
  const pos = await screenPos(TA);
  // 点 wrapper 下半部（field 区域；上部是 label_text），确保聚焦到输入框
  await clickAt(pos.x + pos.w / 2, pos.y + pos.h - 30);
  // 回到 offset 0：Cmd+Left 是 display-line 语义（wrap 段起点），不可靠；
  // 连按 12 次 Alt+Left 从任意落点必达 0（全文只有 8 个词）。旧代码 Alt+Left
  // 卡死时到不了 0，后续断言照样红 —— 回归性不受影响。
  for (let i = 0; i < 12; i++) await key("left", { alt: true });
  let st = await inputState(TA);
  assert(st.buffer_len === 75, `预置文本字节数不是 75: ${st.buffer_len}（story 文本被改动？）`);
  assert(st.cursor_pos === 0, `12×Alt+Left 后 cursor 应为 0，实际 ${st.cursor_pos}（Alt 词跳可能原地卡死）`);

  // Alt+Right：0 → 7 → 14 → 27 → 34 → 40 → 46 → 72 → 75（修复前第一步就停在 0）
  const rightStops = [7, 14, 27, 34, 40, 46, 72, 75];
  for (const expect of rightStops) {
    await key("right", { alt: true });
    st = await inputState(TA);
    assert(st.cursor_pos === expect, `Alt+Right 词跳落点错误: 期望 ${expect}，实际 ${st.cursor_pos}`);
  }
  appendLog(`  [wordnav] Alt+Right stops OK: ${rightStops.join(" ")}`);

  // Alt+Left：75 → 72 → 46 → 40 → 34 → 27 → 14 → 7 → 0
  const leftStops = [72, 46, 40, 34, 27, 14, 7, 0];
  for (const expect of leftStops) {
    await key("left", { alt: true });
    st = await inputState(TA);
    assert(st.cursor_pos === expect, `Alt+Left 词跳落点错误: 期望 ${expect}，实际 ${st.cursor_pos}`);
  }
  appendLog(`  [wordnav] Alt+Left stops OK: ${leftStops.join(" ")}`);

  // 双击选词：把 cursor 摆进 "привет"（14..26）内（byte 20），取 cursor_rect
  // 的屏幕坐标做双击 —— 不做像素估位，坐标由数据读回。
  // （上面 Alt+Left 序列已停在 0）
  await key("right", { alt: true }); // 7
  await key("right", { alt: true }); // 14
  await key("right"); // 16
  await key("right"); // 18
  await key("right"); // 20
  st = await inputState(TA);
  assert(st.cursor_pos === 20, `预备光标应为 20，实际 ${st.cursor_pos}`);
  assert(st.cursor_rect != null, "cursor_rect 缺失，无法定位双击坐标");
  const cxp = st.cursor_rect!.x + 1;
  const cyp = st.cursor_rect!.y + st.cursor_rect!.h / 2;
  await clickAt(cxp, cyp);
  await sleep(60);
  await clickAt(cxp, cyp); // 450ms 内第二击 → 双击选词
  st = await inputState(TA);
  const anchor = st.anchor ?? -1;
  const lo = Math.min(anchor, st.cursor_pos);
  const hi = Math.max(anchor, st.cursor_pos);
  appendLog(`  [wordnav] double-click selection: anchor=${anchor} cursor=${st.cursor_pos}`);
  assert(lo === 14 && hi === 26, `双击选词应选中 "привет" [14,26]，实际 [${lo},${hi}]（修复前为空选区）`);
  await shot("wordnav-selection");
});

test("MultiClick: 双击计数可达 + long_press 按住触发（gesture arena 回归）", async () => {
  // Batch C4：修复前 reset() 每次 down 清零 click_count → double 计数结构性
  // 不可达（此断言在旧代码必红）。Batch A3：story 首帧能加载（switchTo 成功）
  // 本身就是 epoch 首帧 panic 的回归锚。间隔过期（>450ms 计数作废）与
  // pointer-cancel 不可注入，不在本用例断言范围。
  await switchTo("multiclick");
  const pad = await screenPos("story.multiclick.pad");
  const px = pad.x + pad.w / 2;
  const py = pad.y + pad.h / 2;
  const readCount = async (id: string) => {
    const t = await labelText(id);
    const m = t.match(/(\d+)/);
    assert(m != null, `label ${id} 无计数: ${JSON.stringify(t)}`);
    return Number(m![1]);
  };

  const singles0 = await readCount("story.multiclick.single");
  const doubles0 = await readCount("story.multiclick.double");

  await clickAt(px, py);
  await sleep(50);
  await clickAt(px, py); // 450ms 间隔内第二击

  await waitFor(async () => (await readCount("story.multiclick.double")) === doubles0 + 1 ? true : null, getE2eTimeoutMs(5000), 60);
  const singles1 = await readCount("story.multiclick.single");
  assert(singles1 === singles0 + 2, `tap 计数应 +2（每击各一），实际 ${singles0} → ${singles1}`);
  appendLog(`  [multiclick] double ${doubles0} → ${doubles0 + 1}, single ${singles0} → ${singles1}`);

  // long_press：按下保持 —— story 的 before_render 在按住期间持续出帧，
  // gesture_arena.tick 每帧推进时间判定；500ms 后必须 began，抬手后 ended。
  await mouseDown(px, py);
  await waitFor(async () => (await labelText("story.multiclick.long")).includes("began") ? true : null, getE2eTimeoutMs(5000), 100);
  await mouseUp(px, py);
  await waitFor(async () => (await labelText("story.multiclick.long")).includes("ended") ? true : null, getE2eTimeoutMs(5000), 60);
  appendLog(`  [multiclick] long_press began → ended OK`);
  assert((await health()).status === "ok", "app died during gesture test");
});

test("AnimCtl: yoyo 重放起点 / timeline reverse 终止 / keyframes 批量补齐 / spring 退化参数", async () => {
  // Batch C1/C2/C6/C3。全部数据值读回断言；不做动画中途像素断言。
  await switchTo("animctl");

  // ── C2 timeline reverse：播 ~0.4s 后 reverse，必须在有限时间内完成且停在 t=0 ──
  await clickTestId("story.animctl.tl_play");
  await sleep(400);
  const tlMid = await labelText("story.animctl.tl");
  assert(tlMid.includes("state=playing"), `timeline 应在播放中，实际: ${tlMid}`);
  await clickTestId("story.animctl.tl_reverse");
  const tlDone = await waitFor(async () => {
    const t = await labelText("story.animctl.tl");
    return t.includes("state=completed") ? t : null;
  }, getE2eTimeoutMs(8000), 100);
  // 完成必须是"倒放回 0"而非"正放到头"（t=2.00 表示 reverse 没生效/太晚）
  assert(tlDone.includes("t=0.00"), `reverse 后应停在 t=0.00（旧代码永转不停），实际: ${tlDone}`);
  appendLog(`  [animctl] timeline reverse → ${tlDone}`);

  // ── C1 yoyo：first play → completed 停回 from；裸 play() 重放首 tick 必须从 from 起步 ──
  await clickTestId("story.animctl.yoyo_play");
  const yoyoDone = await waitFor(async () => {
    const t = await labelText("story.animctl.yoyo");
    return t.includes("state=completed") ? t : null;
  }, getE2eTimeoutMs(8000), 100);
  const endVal = Number(yoyoDone.match(/value=([-\d.]+)/)?.[1]);
  assert(Number.isFinite(endVal) && endVal < 40, `yoyo 完成应停回 from(20) 附近，实际: ${yoyoDone}`);
  // 重放（裸 play()，不是 restart()）：旧代码 direction 停在 -1 → 从 to=120 倒播
  await clickTestId("story.animctl.yoyo_play");
  const replay = await waitFor(async () => {
    const t = await labelText("story.animctl.yoyo");
    const m = t.match(/replay_first=([-\d.]+)/);
    if (!m) return null;
    const v = Number(m[1]);
    return Number.isFinite(v) && v >= 0 ? v : null; // -1.0 = 尚未采样
  }, getE2eTimeoutMs(5000), 60);
  assert(replay < 70, `yoyo 重放首 tick 应从 from(20) 侧起步（<70），实际 ${replay}（≈120 = 旧代码从 to 倒播）`);
  appendLog(`  [animctl] yoyo end=${endVal} replay_first=${replay}`);

  // ── C6 keyframes：显式推进 1000ms（周期 400ms×4 循环）——一次 update 必须
  //    批量补齐 2 个周期并停在周期内 50%（旧代码 if 单周期 → loops=1, value=100）──
  await clickTestId("story.animctl.kf_reset");
  await clickTestId("story.animctl.kf_step");
  const kf1 = await waitFor(async () => {
    const t = await labelText("story.animctl.kf");
    return t.includes("loops=") && !t.includes("loops=0 value=0.0") ? t : null;
  }, getE2eTimeoutMs(5000), 60);
  assert(kf1.includes("loops=2") && kf1.includes("value=50.0"),
    `帧停滞 1000ms 后应批量补齐 2 周期停在 50%（loops=2 value=50.0），实际: ${kf1}`);
  await clickTestId("story.animctl.kf_step"); // 再 +1000ms → 总 2000ms = 5 周期 > 4 → 完成
  const kf2 = await waitFor(async () => {
    const t = await labelText("story.animctl.kf");
    return t.includes("completed=true") ? t : null;
  }, getE2eTimeoutMs(5000), 60);
  assert(kf2.includes("loops=4") && kf2.includes("value=100.0"),
    `4 循环跑满后应 loops=4 value=100.0，实际: ${kf2}`);
  appendLog(`  [animctl] keyframes ${kf1} → ${kf2}`);

  // ── C3 spring：负 stiffness 已 tick 若干帧，值必须有限（旧代码 NaN 入 style）──
  const springTxt = await waitFor(async () => {
    const t = await labelText("story.animctl.spring");
    const m = t.match(/ticks=(\d+)/);
    return m && Number(m[1]) > 30 ? t : null;
  }, getE2eTimeoutMs(5000), 100);
  assert(!springTxt.includes("nan") && !springTxt.includes("inf"),
    `退化 spring 产出了非有限值: ${springTxt}`);
  const springVal = Number(springTxt.match(/value=([-\d.]+)/)?.[1]);
  assert(Number.isFinite(springVal), `spring value 不可解析: ${springTxt}`);
  // 元素仍可见（translate 有限 → rect 正常返回）
  const box = (await query("story.animctl.springbox"))[0];
  assert(box != null && box.rect.w > 0, "spring 驱动的元素消失（rect 异常）");
  assert(Number.isFinite(box.translate_x ?? 0), `springbox translate_x 非有限: ${box.translate_x}`);
  appendLog(`  [animctl] spring ${springTxt} translate_x=${box.translate_x}`);
});

test("CleanupHooks: 卸载带 cleanup 的子树计数恰好 +1（双触发回归）", async () => {
  // Batch A4：修复前 fireCleanupCallbacks + freeNode 链双触发 → 一次卸载计数 +2。
  await switchTo("cleanup");
  assert((await labelText("story.cleanup.count")) === "cleanups: 0", "初始计数应为 0");
  assert((await query("story.cleanup.child")).length === 1, "child 初始应挂载");

  const tg1 = await clickTestId("story.cleanup.toggle"); // 卸载
  assert(tg1.ok === true, `toggle click 未命中: ${JSON.stringify(tg1)}`);
  await waitFor(async () => (await labelText("story.cleanup.count")) !== "cleanups: 0" ? true : null, getE2eTimeoutMs(5000), 60);
  await sleep(200); // 若有第二次触发，给它时间显形
  const after1 = await labelText("story.cleanup.count");
  assert(after1 === "cleanups: 1", `一次卸载后计数应恰为 1（2 = 双触发回归），实际: ${JSON.stringify(after1)}`);
  assert((await query("story.cleanup.child")).length === 0, "child 应已卸载");

  const tg2 = await clickTestId("story.cleanup.toggle"); // 重新挂载
  assert(tg2.ok === true, `toggle click(remount) 未命中: ${JSON.stringify(tg2)}`);
  await waitFor(async () => (await query("story.cleanup.child")).length === 1 ? true : null, getE2eTimeoutMs(5000), 60);
  const tg3 = await clickTestId("story.cleanup.toggle"); // 再卸载
  assert(tg3.ok === true, `toggle click(2nd unmount) 未命中: ${JSON.stringify(tg3)}`);
  await waitFor(async () => (await labelText("story.cleanup.count")) === "cleanups: 2" ? true : null, getE2eTimeoutMs(5000), 60);
  await sleep(200);
  const after2 = await labelText("story.cleanup.count");
  assert(after2 === "cleanups: 2", `第二轮卸载后计数应恰为 2，实际: ${JSON.stringify(after2)}`);
  appendLog(`  [cleanup] toggle → 1 → remount → toggle → 2 OK`);
});

test("HeavyText: 超 32768 glyph 预算的单帧内容真实画出（overflow 池化路径）", async () => {
  // §5 池化：text renderer overflow instance buffer 改跨帧保留池。
  // 8 层重叠 × 约 40 可见行 × 约 160 字/行 ≈ 5 万 glyph instance，稳超
  // MAX_INSTANCES=32768，强制走 overflow 路径。断言区域像素非空白 + app 存活。
  await switchTo("heavytext");
  await sleep(400); // 重内容首帧 settle
  const path = `${DIR}/story-heavytext-overflow.png`;
  const r = await screenshot(path);
  assert(r.ok === true, `heavytext screenshot 失败: ${JSON.stringify(r)}`);
  const stackPos = await screenPos("story.heavytext.stack");
  // 密集文本区域必须有大量深色像素（overflow 路径把 glyph 丢掉时这里会稀疏/空白）
  assertRegionHasInk(path, stackPos, "heavytext dense region", 5000);
  assert((await health()).status === "ok", "app died rendering heavy text");
  // 再补一帧确认跨帧稳定（保留池复用第二帧才走到）
  await scrollAt(stackPos.x + 10, stackPos.y + 10, 0, 2);
  await sleep(150);
  const path2 = `${DIR}/story-heavytext-overflow-2.png`;
  await screenshot(path2);
  assertRegionHasInk(path2, stackPos, "heavytext dense region (frame 2)", 5000);
});

test("Security Text: 65536 连续空格缩短为 1 byte 后 stale wrap 安全收敛", async () => {
  await switchTo("sectext");
  let focus = await focused();
  for (let i = 0; i < 128 && focus.test_id !== "story.sectext.replace"; i++) {
    await key("tab");
    focus = await focused();
  }
  assert(focus.test_id === "story.sectext.replace", `sectext replacement action was not keyboard reachable: ${JSON.stringify(focus)}`);
  await key("enter");
  const edited = await waitFor(async () => {
    const value = await inputState("story.sectext.input");
    return value.buffer_len === 1 ? value : null;
  }, getE2eTimeoutMs(8000), 80);
  assert(edited.buffer === "x", `sectext edited buffer mismatch: ${JSON.stringify(edited.buffer)}`);
  const status = await waitFor(async () => {
    const value = await labelText("story.sectext.status");
    return value.includes("bytes: 1") ? value : null;
  }, getE2eTimeoutMs(8000), 80);
  assert(status.includes("UTF-8 valid: true"), `缩短后的文本状态异常: ${status}`);
  assert((await health()).status === "ok", "app died after shrinking the long whitespace run");
  appendLog(`  [sectext] ${status}`);
});

test("Lifecycle Stress: Grid 在响应式回调中连续卸载/重挂 10 轮", async () => {
  await switchTo("teardownstress");
  const click = await clickTestId("story.teardownstress.run");
  assert(click.ok === true, `stress button click failed: ${JSON.stringify(click)}`);
  const status = await waitFor(async () => {
    const value = await labelText("story.teardownstress.status");
    return value.includes("completed cycles: 10") ? value : null;
  }, getE2eTimeoutMs(15000), 100);
  assert(status.includes("grid mounted"), `stress 后 Grid 未恢复挂载: ${status}`);
  assert((await query("story.teardownstress.grid")).length === 1, "stress 后 Grid 节点缺失");
  assert((await health()).status === "ok", "app died during reactive Grid teardown stress");
  appendLog(`  [teardownstress] ${status}`);
});

test("Storybook: DevTools shortcut and toolbar open a real window", async () => {
  await shot("storybook-devtools-before-open");

  // macOS Chrome-compatible shortcut: the target Cx flips inspector.enabled,
  // then the Storybook multi-window host materializes the standalone panel.
  await key("i", { cmd: true, alt: true });
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 3000, 40);
  const shortcutTexts: string[] = [];
  const shortcutHeader = (await query("devtools.header.shell"))[0];
  collectText(shortcutHeader, shortcutTexts);
  assert(shortcutTexts.join(" │ ").includes("Zenit Storybook DevTools"),
    `DevTools 快捷键打开了窗口但标题不对: ${shortcutTexts.join(" │ ")}`);
  await shot("storybook-devtools-open-shortcut");

  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-closed-shortcut");

  // Toolbar is the discoverable equivalent of Cmd+Option+I.
  await clickTestId("storybook.devtools");
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-open-toolbar");
  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-closed-toolbar");
});

test("Storybook: DevTools header theme toggle rebuilds panel in the other scheme", async () => {
  await clickTestId("storybook.devtools");
  await waitFor(async () => (await query("devtools.theme.toggle"))[0] ?? null, 3000, 40);
  await shot("storybook-devtools-theme-initial");

  // 点击只置位，下一帧 root hook 切主题并整棵重建——旧 toggle 节点被替换。
  const before = (await query("devtools.theme.toggle"))[0];
  const click = await clickTestId("devtools.theme.toggle");
  assert(click.ok === true, `theme toggle click failed: ${JSON.stringify(click)}`);
  await waitFor(async () => {
    const now = (await query("devtools.theme.toggle"))[0];
    return now && now.id !== before.id ? now : null;
  }, 3000, 40);
  assert((await query("devtools.header.shell")).length === 1, "主题切换后 header 未重建");
  await shot("storybook-devtools-theme-toggled");

  // 再切回来，面板仍完整可用。
  const mid = (await query("devtools.theme.toggle"))[0];
  await clickTestId("devtools.theme.toggle");
  await waitFor(async () => {
    const now = (await query("devtools.theme.toggle"))[0];
    return now && now.id !== mid.id ? now : null;
  }, 3000, 40);
  assert((await query("devtools.search.input")).length === 1, "切回后搜索栏缺失");
  await shot("storybook-devtools-theme-restored");
  assert((await health()).status === "ok", "app died during DevTools theme toggle");

  await clickTestId("devtools.close");
  await waitFor(async () => (await query("storybook.devtools"))[0] ?? null, 3000, 40);
});

// ── GPU 性能回归门禁 ──
//
// 目的：让 GPU 侧性能回退能被 CI 抓到（此前是**零门禁** —— renderer 一直采集
// 真 GPU 时间，但从没投影到 harness，数据到不了测试侧）。
//
// 为什么只卡 gpu_p95_us，不卡 cpu/total：
//   实测（本机 6 轮 × 2 场景）gpu_p95 稳定在 1220~1811us；
//   而同批次 cpu_p95 在 6309~95847us 之间摆动（同样负载 15× 抖动）——
//   因为 e2e 用 file-RPC 驱动，轮询/调度停顿全算进 CPU 帧墙钟。
//   拿 cpu_p95 当门禁必然周期性假红（ROADMAP 记着 e2e 本来就 flaky，
//   门禁不能再加剧）。GPU 执行时间来自 MTLCommandBuffer 时间戳，
//   不受 RPC 停顿影响，是这里唯一可靠的量。
//
// 阈值依据：实测 max 1811us → 取 8000us（~4.4x 余量）。
//   刻意设得很松：宁可漏报小回退，也不要误报 —— 一条会随机变红的门禁
//   等于没有门禁（历史教训：假红门禁会被直接无视）。
//   真正的大回退（掉一个数量级的缓存、每帧重编 PSO）远超这个量级。
const GPU_P95_BUDGET_US = 8000;
// 样本下限：P95 在样本太少时无意义；且空环会返回 0 ——
// 不检查样本数就等于写了一条"永远绿"的假门禁。
const MIN_TIMING_SAMPLES = 30;

for (const key of ["datatable", "virtuallist"]) {
  test(`perf gate: ${key} 滚动 GPU 帧时间 P95 < ${GPU_P95_BUDGET_US}us`, async () => {
    await switchTo(key);
    await sleep(700); // 等入场/布局 settle，避免首帧 PSO 编译污染样本
    await resetTiming(); // 清环 → P95 只统计本场景自己的帧
    // 制造真实滚动负载（retained 层重画 + path/text 管线持续出货）
    for (let i = 0; i < 25; i++) {
      await scrollAt(700, 400, 0, -60);
      await sleep(25);
    }
    const s = await stats();
    appendLog(
      `  [perf:${key}] samples=${s.timing_samples} gpu_p95=${s.gpu_p95_us}us ` +
      `cpu_p95=${s.cpu_p95_us}us total_p95=${s.total_p95_us}us ` +
      `(last frame: gpu=${s.gpu_execute_us} layout=${s.layout_us} render_gen=${s.render_gen_us} encode=${s.gpu_encode_us})`,
    );
    // 先验证门禁本身有效：样本不足时 P95 恒 0，断言会假绿。
    assert(
      s.timing_samples >= MIN_TIMING_SAMPLES,
      `计时样本不足 ${s.timing_samples} < ${MIN_TIMING_SAMPLES} — P95 不可信（门禁失效而非通过）`,
    );
    assert(
      s.gpu_p95_us > 0,
      `gpu_p95_us 为 0 —— GPU 时间戳管线没出货，门禁形同虚设`,
    );
    assert(
      s.gpu_p95_us < GPU_P95_BUDGET_US,
      `GPU 帧时间回退：${key} 滚动 gpu_p95=${s.gpu_p95_us}us 超预算 ${GPU_P95_BUDGET_US}us ` +
      `(本机基线 ~1.2-1.8ms)。细分见 log 的 layout/render_gen/encode。`,
    );
  });
}

test("Surface: resize 后 screenshot readback 仍有效（usage 单一出口回归）", async () => {
  // 回归：maybeReconfigureSurface 曾硬编码 .color_target_only，resize 触发
  // surface 重配后 test-mode 丢 CPU readback 能力，此后 /screenshot 全部
  // 失败或读花屏。现 init 与 resize 共用 surfaceConfigFor 单一出口。
  const before = `${DIR}/resize-readback-before.png`;
  const shotBefore = await screenshot(before);
  assert(shotBefore.ok === true, `resize 前基线截图失败: ${JSON.stringify(shotBefore)}`);
  const pngBefore = decodePng(before);

  const r = await resizeWindow(900, 800);
  assert((r as any).ok === true, `resize 请求失败: ${JSON.stringify(r)}`);
  await sleep(400); // 等主循环完成 surface 重配 + 呈现新帧

  const after = `${DIR}/resize-readback-after.png`;
  const shotAfter = await screenshot(after);
  assert(shotAfter.ok === true, `resize 后截图失败（readback 能力在重配时丢失）: ${JSON.stringify(shotAfter)}`);
  const pngAfter = decodePng(after);
  assert(pngAfter.width > 0 && pngAfter.height > 0, "resize 后 png 解码失败");
  // 尺寸真的变了（证明重配确实发生过，而非窗口没动、测试测了空气）
  assert(
    pngAfter.width !== pngBefore.width || pngAfter.height !== pngBefore.height,
    `drawable 尺寸未变化（before=${pngBefore.width}x${pngBefore.height} after=${pngAfter.width}x${pngAfter.height}）— resize 未生效，本用例没测到重配路径`,
  );
  // 内容真实（非全黑/全白花屏）：全图必须有足量深色像素
  const dark = countDarkPixels(pngAfter, { x: 0, y: 0, w: 900, h: 800 }, pngAfter.width / 900);
  appendLog(`  [resize-readback] after=${pngAfter.width}x${pngAfter.height} dark=${dark}`);
  assert(dark >= 500, `resize 后截图疑似花屏/空白（dark=${dark}）`);

  // 恢复初始尺寸，避免影响潜在的后续用例/人工比对
  await resizeWindow(1100, 1000);
  await sleep(200);
});

// ── Popover autosize：超高内容不得盖住 trigger ──
// floating-ui `size` 的 availableHeight → max-height 对齐。修前 caller 未设 max_height
// 的 popover 在两侧都放不下时保持完整高度，best-fit 只挪 translate，面板下缘
// 越过 trigger 把 reference element 盖住。
test("popover: tall content shrinks to viewport and never covers its trigger", async () => {
  await switchTo("popover");
  const trigger = (await query("story.popover.tall.trigger"))[0];
  assert(trigger != null && trigger.rect.h > 0, "tall popover trigger 不存在");
  const click = await clickTestId("story.popover.tall.trigger");
  assert(click.ok === true, `tall popover trigger click failed: ${JSON.stringify(click)}`);
  const content = await waitFor(async () => {
    const node = (await query("story.popover.tall.content"))[0];
    return node != null && node.rect.w > 0 && node.rect.h > 0 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  await sleep(400); // autosize 下一帧才应用 max_height + enter 动画 settle
  const settled = (await query("story.popover.tall.content"))[0];
  assert(settled != null, "tall popover content 消失");
  appendLog(`  trigger=${JSON.stringify(trigger.rect)} content(first)=${JSON.stringify(content.rect)} content(settled)=${JSON.stringify(settled.rect)}`);
  await shot("popover-tall-autosize");
  // storybook 窗口固定 1100x1000（examples/storybook/main.zig），rect 为窗口逻辑坐标
  const vpH = 1000;
  // 前置条件：内容本身确实超过窗口（否则断言在测空气）
  assert(settled.rect.h < 1400, `面板高度 ${settled.rect.h} 未被收紧（内容 1400+px）`);
  assert(settled.rect.h <= vpH, `面板高度 ${settled.rect.h} 超出 viewport ${vpH}`);
  assert(settled.rect.y >= 0 && settled.rect.y + settled.rect.h <= vpH, `面板越出 viewport: ${JSON.stringify(settled.rect)}`);
  assert(!rectsOverlap(settled.rect, trigger.rect), `面板盖住了 trigger: content=${JSON.stringify(settled.rect)} trigger=${JSON.stringify(trigger.rect)}`);
  // 子内容必须被 chrome 裁切：面板下缘外 2px 处不能再是靛蓝色块（只收外壳不裁子节点 = 没收）
  const below = { x: settled.rect.x + settled.rect.w / 2 - 2, y: settled.rect.y + settled.rect.h + 2, w: 4, h: 4 };
  assert(below.y + below.h <= vpH, `面板下缘距 viewport 太近，采样点越界: ${JSON.stringify(below)}`);
  const px = centerPixel(`${DIR}/story-popover-tall-autosize.png`, below);
  appendLog(`  pixel below panel=${JSON.stringify(px)}`);
  // 内容是高饱和渐变块；面板外是灰白背景/描边——出现高饱和色即内容溢出
  const saturation = Math.max(...px) - Math.min(...px);
  assert(saturation < 60, `面板下缘外仍是内容色块（未裁切）: ${JSON.stringify(px)}`);
  // fit_or_scroll：超出 cap 的内容在面板内纵向滚动（滚动内容上移、面板外壳不动）
  const scrollBefore = (await query("story.popover.tall.scroll_content"))[0];
  assert(scrollBefore != null && scrollBefore.rect.h > settled.rect.h, `滚动内容应高于面板: ${JSON.stringify(scrollBefore?.rect)}`);
  for (let i = 0; i < 10; i++) {
    await scrollAt(settled.rect.x + settled.rect.w / 2, settled.rect.y + settled.rect.h / 2, 0, -30);
    await sleep(16);
  }
  const scrollAfter = await waitFor(async () => {
    const node = (await query("story.popover.tall.scroll_content"))[0];
    return node != null && node.rect.y < scrollBefore.rect.y - 100 ? node : null;
  }, getE2eTimeoutMs(2000), 50);
  const panelAfter = (await query("story.popover.tall.content"))[0];
  appendLog(`  scroll_content before=${JSON.stringify(scrollBefore.rect)} after=${JSON.stringify(scrollAfter.rect)} panel=${JSON.stringify(panelAfter?.rect)}`);
  assert(panelAfter != null && Math.abs(panelAfter.rect.y - settled.rect.y) < 1 && Math.abs(panelAfter.rect.h - settled.rect.h) < 1, `面板内滚动不应移动面板外壳: ${JSON.stringify(panelAfter?.rect)}`);
  await key("escape");
  await sleep(300);
});

test("Storybook 搜索: 输入过滤导航、分组标题随行隐藏、无匹配提示、清空恢复", async () => {
  const sidebarText = async (): Promise<string[]> => {
    const out: string[] = [];
    const t = await query("sidebar");
    if (t[0]) collectText(t[0], out);
    return out;
  };
  const clearSearch = async () => {
    await clickTestId("storybook.search");
    await key("a", { cmd: true });
    await key("backspace");
    await sleep(250);
  };

  await clickTestId("storybook.search");
  await type_("glass");
  await sleep(300);
  let out = await sidebarText();
  appendLog(`  search "glass": ${out.join(" │ ")}`);
  assert(out.includes("GlassBox") && out.includes("GlassLab"), `应保留 Glass* 行 — ${out.join(" │ ")}`);
  assert(out.includes("MATERIALS & MOTION"), `匹配行的分组标题应保留 — ${out.join(" │ ")}`);
  assert(!out.includes("Button") && !out.includes("CONTROLS"), `不匹配的行与空分组应隐藏 — ${out.join(" │ ")}`);
  await shot("search-glass");

  // 过滤后的行照常可点
  await clickTestId("nav.glasslab");
  await sleep(300);
  assert((await query("story.glasslab")).length > 0, "点击过滤结果应切到 GlassLab story");

  await clearSearch();
  await clickTestId("storybook.search");
  await type_("zzzz-nope");
  await sleep(300);
  out = await sidebarText();
  assert(out.includes("No matching components"), `无匹配应显示提示 — ${out.join(" │ ")}`);
  await shot("search-empty");

  await clearSearch();
  out = await sidebarText();
  assert(out.includes("Button") && out.includes("CONTROLS") && out.includes("GlassBox"), `清空后应恢复完整列表 — ${out.join(" │ ")}`);
  assert(!out.includes("No matching components"), "清空后不应残留无匹配提示");
  await switchTo("button");
});

// 同档 Input / Select / Button 混排：外框高度 = ControlSize 推导值且同一行垂直中心一致。
test("Form Composition: same-size Input/Select/Button share height and center line", async () => {
  await switchTo("formcompose");
  const expected: Record<string, number> = { xs: 20, sm: 24, md: 32, lg: 40 };
  for (const [size, h] of Object.entries(expected)) {
    const rects: Record<string, { x: number; y: number; w: number; h: number }> = {};
    for (const part of ["input", "status", "owner", "reset", "apply"]) {
      const node = (await query(`story.formcompose.${size}.${part}`))[0];
      assert(node?.rect != null, `缺 story.formcompose.${size}.${part}`);
      rects[part] = node.rect;
    }
    appendLog(`  ${size}: ${Object.entries(rects).map(([k, r]) => `${k} y=${r.y.toFixed(1)} h=${r.h.toFixed(1)}`).join(" | ")}`);
    const cy0 = rects.input.y + rects.input.h / 2;
    for (const [part, r] of Object.entries(rects)) {
      assert(Math.abs(r.h - h) < 0.5, `${size}.${part} 高度 ${r.h} ≠ ControlSize ${h}`);
      assert(Math.abs(r.y + r.h / 2 - cy0) < 0.5, `${size}.${part} 垂直中心 ${r.y + r.h / 2} 与 input ${cy0} 不齐`);
    }
    const row = (await query(`story.formcompose.${size}.row`))[0];
    const panel = (await query("story.formcompose"))[0];
    assert(row.rect.x + row.rect.w <= panel.rect.x + panel.rect.w, `${size} 工具栏超出预览区: ${JSON.stringify(row.rect)}`);
  }
  await shot("formcompose-alignment");
});

run();
