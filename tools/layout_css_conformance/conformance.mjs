// This mapping is intentionally CSS semantics; do not emulate known engine bugs here.
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const hyphen = s => s.replaceAll('_', '-');
const align = s => s === 'first_baseline' ? 'first baseline' : ['start','end'].includes(s) ? `flex-${s}` : hyphen(s);
const fields = new Set(('width height direction justify align_items align_content gap padding margin flex flex_shrink flex_basis flex_wrap align_self no_cross_stretch margin_auto_mask position inset sticky_insets min_width max_width min_height max_height aspect_ratio display overflow overflow_hidden layout_isolation translate_x translate_y border grid grid_placement').split(' '));
const sides = ['top','right','bottom','left'];
const defaults = {width:{fit:{}},height:{fit:{}},direction:'column',align_items:'stretch'};
export function parseSuite(value) {
  const suite = typeof value === 'string' ? JSON.parse(value) : value;
  if (suite.version !== 1 || !Array.isArray(suite.fixtures) || !suite.fixtures.length) throw Error('Invalid fixture suite');
  const fixtures = new Set();
  for (const f of suite.fixtures) {
    if (!f.id || fixtures.has(f.id) || !Array.isArray(f.properties) || f.properties.length === 0 || !(f.width > 0 && f.height > 0)) throw Error('Invalid fixture');
    fixtures.add(f.id);
    if (f.must_match !== undefined && typeof f.must_match !== 'boolean') throw Error('Invalid must_match');
    if (f.note !== undefined && (typeof f.note !== 'string' || !f.note.trim())) throw Error('Invalid fixture note');
    if (f.known_engine_deviation !== undefined) {
      const deviations = f.known_engine_deviation;
      if (!deviations || typeof deviations !== 'object' || Array.isArray(deviations)) throw Error('Invalid known engine deviation');
      for (const [engine,reason] of Object.entries(deviations)) {
        if (!['chromium','firefox','webkit'].includes(engine) || typeof reason !== 'string' || !reason.trim() || !/https:\/\/\S+/.test(reason)) throw Error('Known engine deviation requires a supported engine, reason and HTTPS reference');
      }
    }
    const ids = new Set();
    function walk(n, depth=0) {
      if (depth > 64 || !n.id || ids.has(n.id)) throw Error('Invalid or duplicate node id');
      ids.add(n.id);
      for (const [k,v] of Object.entries(n.style ?? {})) {
        if (!fields.has(k)) throw Error(`Unknown property ${k}`);
        if (k === 'width' || k === 'height') {
          const keys = Object.keys(v ?? {});
          if (keys.length !== 1 || !['px','grow','fit','percent'].includes(keys[0])) throw Error('Invalid sizing');
        }
        if (k === 'flex_basis' && !(typeof v === 'number' && v >= 0 || ['auto','content'].includes(v))) throw Error('Invalid flex basis');
        if (typeof v === 'number' && !Number.isFinite(v)) throw Error('Non-finite value');
      }
      if (n.style?.layout_isolation && ['width','height'].some(k => !n.style[k] || 'fit' in n.style[k])) throw Error('Isolation requires definite sizing');
      if (n.style?.grid && (!n.style.grid.columns.length || n.style.grid.columns.length > 16 || (n.style.grid.rows?.length ?? 0) > 16)) throw Error('Invalid grid tracks');
      if (n.style?.grid) {
        const breadth = (v, minimum=false) => {
          if (v === 'auto') return;
          if (!v || typeof v !== 'object' || Array.isArray(v) || Object.keys(v).length !== 1) throw Error('Invalid grid track');
          const [key,num] = Object.entries(v)[0];
          if (!['px',...(minimum ? [] : ['fr'])].includes(key) || typeof num !== 'number' || !Number.isFinite(num) || num < 0) throw Error('Invalid grid breadth');
        };
        for (const v of [...n.style.grid.columns,...(n.style.grid.rows ?? [])]) {
          if (v && typeof v === 'object' && 'minmax' in v) {
            if (Object.keys(v).length !== 1 || !v.minmax || Object.keys(v.minmax).some(k => !['min','max'].includes(k))) throw Error('Invalid minmax track');
            breadth(v.minmax.min ?? 'auto',true); breadth(v.minmax.max ?? 'auto');
          } else breadth(v);
        }
      }
      if (n.text?.overflow_wrap && !['normal','break_word','anywhere'].includes(n.text.overflow_wrap)) throw Error('Invalid overflow wrap');
      if (n.text?.word_break && !['normal','break_all','keep_all'].includes(n.text.word_break)) throw Error('Invalid word break');
      if (n.text && (!Number.isInteger(n.text.font_size ?? 16) || ![16,32].includes(n.text.font_size ?? 16))) throw Error('Text corpus uses fixed font sizes 16/32');
      for (const child of n.children ?? []) walk(child, depth+1);
    }
    walk(f.root);

  }
  return suite;
}
export function styleCSS(input = {}, parent = null, text = null) {
  const s = {...defaults, ...input};
  const row = (parent?.direction ?? 'column').startsWith('row');
  const main = row ? 'width' : 'height';
  const cross = row ? 'height' : 'width';
  const css = {display:s.grid ? 'grid' : (s.display ?? 'flex'), position:s.position ?? 'relative', 'box-sizing':'border-box', 'flex-direction':hyphen(s.direction), 'align-items':align(s.align_items), 'align-content':align(s.align_content ?? 'normal'), 'justify-content':align(s.justify ?? 'start'), gap:`${s.gap ?? 0}px`, 'flex-shrink':s.flex_shrink ?? 1, 'flex-grow':0};
  if (s.display === 'none') css.display = 'none';
  for (const axis of ['width','height']) {
    const [kind, v] = Object.entries(s[axis])[0];
    css[axis] = kind === 'px' ? `${v}px` : kind === 'percent' ? `${v}%` : kind === 'grow' || axis === cross ? 'auto' : 'max-content';
    if (kind === 'grow' && axis === main && parent && !parent.grid) {
      css['flex-grow'] = s.flex ?? 1;
      css['flex-basis'] = 'auto';
    }
    if (kind === 'grow' || kind === 'fit') {
      // Only explicit SizingMinMax bounds become CSS constraints. An omitted min keeps CSS
      // automatic minimum sizing (the CSS-aligned target), so Zenit's implicit min=0 shows up as a
      // difference instead of being copied into the browser oracle.
      if (v.min !== undefined) css[`min-${axis}`] = `${v.min}px`;
      if (v.max !== undefined) css[`max-${axis}`] = `${v.max}px`;
    }
    // Ext and Sizing constraints intersect. CSS min wins if min exceeds max.
    const low = s[`min_${axis}`], high = s[`max_${axis}`];
    if (low !== undefined) css[`min-${axis}`] = `${Math.max(low, Number.parseFloat(css[`min-${axis}`] ?? '0'))}px`;
    if (high !== undefined) css[`max-${axis}`] = `${Math.min(high, Number.parseFloat(css[`max-${axis}`] ?? 'Infinity'))}px`;
  }
  if ('flex_basis' in s) css['flex-basis'] = typeof s.flex_basis === 'string' ? s.flex_basis : `${s.flex_basis}px`;
  css['flex-wrap'] = s.flex_wrap === 'wrap_reverse' ? 'wrap-reverse' : s.flex_wrap === 'wrap' ? 'wrap' : 'nowrap';
  if (s.align_self) css['align-self'] = align(s.align_self);
  else if (s.no_cross_stretch && (parent?.align_items ?? 'stretch') === 'stretch') css['align-self'] = 'flex-start';
  for (const side of sides) {
    css[`padding-${side}`] = `${s.padding?.[side] ?? 0}px`;
    css[`margin-${side}`] = (s.margin_auto_mask ?? 0) & (1 << sides.indexOf(side)) ? 'auto' : `${s.margin?.[side] ?? 0}px`;
    const inset = s.position === 'sticky' ? s.sticky_insets?.[side] : s.inset?.[side];
    if (typeof inset === 'number') css[side] = `${inset}px`;
    else if (inset && typeof inset === 'object') css[side] = 'px' in inset ? `${inset.px}px` : `${inset.percent}%`;
  }
  css.overflow = s.overflow_hidden ? 'hidden' : s.overflow ?? 'visible';
  if (s.aspect_ratio) css['aspect-ratio'] = s.aspect_ratio;
  if (s.translate_x || s.translate_y) css.transform = `translate(${s.translate_x ?? 0}px,${s.translate_y ?? 0}px)`;
  if (s.layout_isolation) css.contain = 'layout';
  if (s.border && !s.border.overlay) {
    css['border-style'] = 'solid';
    for (const [i,side] of sides.entries()) css[`border-${side}-width`] = `${(s.border.side_widths?.[i] ?? -1) >= 0 ? s.border.side_widths[i] : Math.max(0,s.border.width ?? 0)}px`;
  }
  if (s.grid) {
    const track = v => typeof v === 'string' ? hyphen(v) : 'minmax' in v ? `minmax(${track(v.minmax.min ?? 'auto')},${track(v.minmax.max ?? 'auto')})` : 'px' in v ? `${v.px}px` : `${v.fr}fr`;
    css['grid-template-columns'] = s.grid.columns.map(track).join(' ');
    if (s.grid.rows?.length) css['grid-template-rows'] = s.grid.rows.map(track).join(' ');
    css['column-gap'] = `${s.grid.column_gap ?? 0}px`;
    css['row-gap'] = `${s.grid.row_gap ?? 0}px`;
  }
  if (s.grid_placement) {
    const p = s.grid_placement;
    css['grid-column'] = `${p.col_start || 'auto'} / span ${p.col_span ?? 1}`;
    css['grid-row'] = `${p.row_start || 'auto'} / span ${p.row_span ?? 1}`;
  }
  if (text) {
    css.display = s.display === 'none' ? 'none' : 'block';
    css['font-family'] = 'LC1'; css['font-size'] = `${text.font_size ?? 16}px`;
    css['font-kerning'] = 'normal';
    css['font-feature-settings'] = 'normal';
    css['font-variant-ligatures'] = 'common-ligatures contextual no-discretionary-ligatures no-historical-ligatures';
    css['letter-spacing'] = '0px'; css['word-spacing'] = '0px';
    css['text-rendering'] = 'optimizeLegibility'; css['font-synthesis'] = 'none';
    css['font-optical-sizing'] = 'none'; css['-webkit-text-size-adjust'] = '100%';
    css['font-weight'] = 400; css['line-height'] = text.line_height ?? 1.4;
    css['white-space'] = ['none','newline_only'].includes(text.wrap ?? 'none') ? 'pre' : 'pre-wrap';
    css['overflow-wrap'] = text.overflow_wrap && text.overflow_wrap !== 'normal' ? hyphen(text.overflow_wrap) : text.wrap === 'char' ? 'anywhere' : text.wrap === 'word_break' ? 'break-word' : 'normal';
    css['word-break'] = text.word_break && text.word_break !== 'normal' ? hyphen(text.word_break) : text.wrap === 'break_all' ? 'break-all' : text.wrap === 'keep_all' ? 'keep-all' : 'normal';
    if (['ellipsis','ellipsis_smart'].includes(text.text_overflow)) { css['text-overflow'] = 'ellipsis'; css.overflow = 'hidden'; }
    if (text.fade_right > 0) css['mask-image'] = `linear-gradient(to right,black calc(100% - ${text.fade_right}px),transparent)`;
    if (text.max_lines) { css.display = '-webkit-box'; css['-webkit-box-orient'] = 'vertical'; css['-webkit-line-clamp'] = text.max_lines; css.overflow = 'hidden'; }
  }
  return Object.entries(css).map(([k,v]) => `${k}:${v}`).join(';');
}
export function html(f, fontURL) {
  function node(n, parent) {
    return `<div data-id="${esc(n.id)}" style="${esc(styleCSS(n.style, parent, n.text))}">${n.text ? esc(n.text.content) : ''}${(n.children ?? []).map(c => node(c, {...defaults,...n.style})).join('')}</div>`;
  }
  return `<!doctype html><meta charset="utf-8"><style>@font-face{font-family:LC1;src:url('${fontURL}')}html,body{margin:0;padding:0}body{width:${f.width}px;height:${f.height}px}</style>${node(f.root, null)}`;
}
export function compare(f, zenit, browser, tolerance = 0.5) {
  const z = new Map(zenit.map(n => [n.id,n])), b = new Map(browser.map(n => [n.id,n]));
  const expected = [];
  const walk = n => {expected.push(n.id);for (const c of n.children ?? []) walk(c);};
  walk(f.root);
  if (z.size !== zenit.length || b.size !== browser.length) throw Error('Duplicate oracle node id');
  const nodes = [...new Set([...expected, ...z.keys(), ...b.keys()])].map(id => {
    const a = z.get(id), c = b.get(id);
    const delta = a && c ? Object.fromEntries(['x','y','w','h'].map(k => [k,c[k]-a[k]])) : null;
    const match = !!delta && Object.values(delta).every(v => Number.isFinite(v) && Math.abs(v) <= tolerance);
    return {id,zenit:a ?? null,browser:c ?? null,delta,match};
  });
  return {id:f.id,properties:f.properties,must_match:!!f.must_match,match:nodes.every(n => n.match),known_engine_deviation:f.known_engine_deviation ?? {},note:f.note,nodes};
}
export function summarize(results) {
  const summary = {};
  for (const f of results) for (const p of f.properties) {
    const v = summary[p] ??= {fixtures:0,different:0,knownDeviations:0,nodes:0,differentNodes:0};
    v.fixtures++; v.different += !f.match && !f.knownDeviation; v.knownDeviations += !!f.knownDeviation; v.nodes += f.nodes.length; v.differentNodes += f.nodes.filter(n => !n.match).length;
  }
  return summary;
}
export const loadSuite = path => parseSuite(readFileSync(path,'utf8'));

// An annotation qualifies only with two distinct measured engines agreeing
// with Zenit and each other over the complete fixture. A specification citation
// or numeric contract cannot substitute for an independent browser measurement.
export function classifyEngineDeviations(reports) {
  const axes = ['x','y','w','h'];
  const finite = f => f && f.nodes.every(n => n.zenit && n.browser && axes.every(k => Number.isFinite(n.zenit[k]) && Number.isFinite(n.browser[k])));
  const agrees = (a,b) => a.nodes.length === b.nodes.length && a.nodes.every(n => {
    const peer = b.nodes.find(v => v.id === n.id);
    return peer && axes.every(k => Math.abs(n.browser[k]-peer.browser[k]) <= 0.5);
  });
  for (const report of reports) for (const fixture of report.fixtures) {
    delete fixture.knownDeviation;
    const reason = fixture.known_engine_deviation?.[report.engine];
    if (report.status !== 'measured' || fixture.match || !reason || !finite(fixture)) continue;
    const peers = reports.filter(r => r.status === 'measured' && r.engine !== report.engine)
      .map(r => ({engine:r.engine,fixture:r.fixtures.find(f => f.id === fixture.id)}))
      .filter(r => finite(r.fixture) && r.fixture.nodes.length === fixture.nodes.length &&
        fixture.nodes.every(n => {
          const peer = r.fixture.nodes.find(v => v.id === n.id);
          return peer && axes.every(k => Math.abs(n.zenit[k]-peer.browser[k]) <= 0.5);
        }));
    const pair = peers.flatMap((a,i) => peers.slice(i+1)
      .filter(b => a.engine !== b.engine && agrees(a.fixture,b.fixture))
      .map(b => [a.engine,b.engine]))[0];
    if (pair) fixture.knownDeviation = {reason,corroboratingEngines:pair};
  }
  for (const report of reports) if (report.status === 'measured') report.summary = summarize(report.fixtures);
}
export function reportsFailed(reports, {enforce=false,requireAll=false,expectedFixtureIds=[]} = {}) {
  if (!reports.some(r => r.status === 'measured')) return true;
  return reports.some(r => (r.status === 'measured' && (r.fixtures.length !== expectedFixtureIds.length || expectedFixtureIds.some(id => r.fixtures.filter(f => f.id === id).length !== 1)) && expectedFixtureIds.length > 0) || r.status === 'error' ||
    (r.status !== 'measured' && (r.engine === 'chromium' || requireAll)) ||
    (enforce && r.fixtures.some(f => f.must_match && !f.match && !f.knownDeviation)));
}


// A native process cannot qualify its own geometry by printing success first.
// Bound execution, require clean termination, and reject allocator diagnostics
// even when the program has written a complete result and returned zero.
export function runNative(executable, args, {timeout=120000}={}) {
  const native = spawnSync(executable,args,{encoding:'utf8',timeout,killSignal:'SIGKILL',maxBuffer:16*1024*1024});
  const output = (native.stdout ?? '') + (native.stderr ?? '');
  if (native.error || native.signal || native.status !== 0 || /panic:|memory address .* leaked|\[gpa\].*leak|error:.*leak/i.test(output)) {
    throw Error(`Zenit failed: status=${native.status}, signal=${native.signal}, error=${native.error?.message ?? ''}\n${output}`);
  }
  return native;
}
