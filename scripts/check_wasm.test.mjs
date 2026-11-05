// Falsify the controller with tiny real wasm modules. Printed success markers
// must never override missing exports, traps, wrong results or timeouts.
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const names = ['smoke_reactive', 'smoke_layout', 'smoke_missing_measure', 'smoke_unsupported_font', 'smoke_i18n', 'smoke_measure', 'smoke_environment'];
const leb = value => { const out = []; do { let b = value & 127; value >>>= 7; if (value) b |= 128; out.push(b); } while (value); return out; };
const str = value => [...leb(Buffer.byteLength(value)), ...Buffer.from(value)];
const section = (id, bytes) => [id, ...leb(bytes.length), ...bytes];
function fixture(kind) {
  const exported = kind === 'missing' ? names.filter(n => n !== 'smoke_layout') : names;
  const code = kind === 'trap' ? [0, 0x00, 0x0b]
    : kind === 'timeout' ? [0, 0x03, 0x40, 0x0c, 0, 0x0b, 0x41, 0, 0x0b]
    : [0, 0x41, 0, 0x0b];
  return Uint8Array.from([
    0, 97, 115, 109, 1, 0, 0, 0,
    ...section(1, [2, 0x60, 0, 1, 0x7e, 0x60, 0, 1, 0x7f]),
    ...section(2, [1, ...str('zenit'), ...str('now_ns'), 0, 0]),
    ...section(3, [1, 1]),
    ...section(5, [1, 0, 1]),
    ...section(7, [exported.length + 1, ...str('memory'), 2, 0,
      ...exported.flatMap(name => [...str(name), 0, 1])]),
    ...section(10, [1, ...leb(code.length), ...code]),
  ]);
}
const dir = mkdtempSync(join(tmpdir(), 'zenit-wasm-controller-'));
try {
  const oracle = join(dir, 'oracle.json');
  writeFileSync(oracle, JSON.stringify({ reactive: 42, rect: [60, 30, 240, 40], i18n: 1, measure: 21 }));
  const wrapper = join(dir, 'marker.mjs');
  writeFileSync(wrapper, `console.log('wasm smoke PASS (untrusted marker)'); await import(${JSON.stringify(new URL('./check_wasm.mjs', import.meta.url).href)});`);
  for (const [kind, diagnostic] of [['missing', /missing export/], ['trap', /unreachable/], ['wrong', /0 !== 42/], ['timeout', /timed out/]]) {
    const path = join(dir, `${kind}.wasm`);
    writeFileSync(path, fixture(kind));
    const result = spawnSync(process.execPath, [wrapper, path, oracle, '500'], { encoding: 'utf8', timeout: 5000 });
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status, 1, `${kind}: ${result.stderr}`);
    assert.match(result.stdout, /untrusted marker/);
    assert.match(result.stderr, diagnostic);
    console.log(`wasm controller rejects ${kind} after success marker: PASS`);
  }
} finally { rmSync(dir, { recursive: true, force: true }); }
