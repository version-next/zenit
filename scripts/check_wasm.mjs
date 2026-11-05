import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

// A worker lets the parent terminate synchronous infinite wasm loops, too.
if (isMainThread) {
  const [wasm, oracle, timeoutArg] = process.argv.slice(2);
  assert(wasm && oracle, 'usage: node scripts/check_wasm.mjs smoke.wasm native-oracle.json');
  const timeoutMs = timeoutArg === undefined ? 30_000 : Number(timeoutArg);
  assert(Number.isSafeInteger(timeoutMs) && timeoutMs > 0, 'timeout must be a positive integer');
  let completed = false;
  const worker = new Worker(new URL(import.meta.url), { workerData: { wasm, oracle } });
  const timeout = setTimeout(() => {
    console.error('wasm smoke timed out');
    process.exitCode = 1;
    void worker.terminate();
  }, timeoutMs);
  worker.on('error', error => { console.error(error); process.exitCode = 1; });
  worker.on('message', message => { completed = true; console.log(message); });
  worker.on('exit', code => { clearTimeout(timeout); if (code !== 0 || !completed) process.exitCode = 1; });
} else {
  const expected = JSON.parse(await readFile(workerData.oracle, 'utf8'));
  const module = await WebAssembly.compile(await readFile(workerData.wasm));
  assert.deepEqual(WebAssembly.Module.imports(module), [{ module: 'zenit', name: 'now_ns', kind: 'function' }]);
  let clockCalls = 0;
  const { exports } = await WebAssembly.instantiate(module, { zenit: { now_ns: () => { clockCalls++; return process.hrtime.bigint(); } } });
  assert(exports.memory instanceof WebAssembly.Memory, 'exported wasm memory required');
  for (const name of ['smoke_reactive', 'smoke_layout', 'smoke_missing_measure', 'smoke_unsupported_font', 'smoke_i18n', 'smoke_measure', 'smoke_environment']) {
    assert.equal(typeof exports[name], 'function', `missing export ${name}`);
  }
  for (let i = 0; i < 3; i++) {
    assert.equal(exports.smoke_reactive(), expected.reactive);
    assert.equal(exports.smoke_i18n() >>> 0, expected.i18n);
    assert.equal(exports.smoke_measure(), expected.measure);
    assert.equal(new Uint32Array(new Float32Array([exports.smoke_measure()]).buffer)[0], expected.measure_bits, 'measure must match the native f32 bit pattern');
    assert.equal(exports.smoke_environment(), 1);
    const ptr = exports.smoke_layout();
    assert.deepEqual(Array.from(new Float32Array(exports.memory.buffer, ptr, 4)), expected.rect);
    assert.deepEqual(Array.from(new Uint32Array(exports.memory.buffer, ptr, 4)), expected.rect_bits, 'rect must match the native f32 bit patterns');
  }
  assert(clockCalls >= 3, 'Cx must use the imported host clock');
  assert.equal(exports.smoke_unsupported_font(), 1, 'native font creation must return Unsupported');
  assert.throws(() => exports.smoke_missing_measure(), WebAssembly.RuntimeError, 'missing measurement hook must trap');
  parentPort.postMessage(`wasm smoke PASS: reactive=${expected.reactive}, rect=${JSON.stringify(expected.rect)}, i18n=${expected.i18n}, measure=${expected.measure}, host clock calls=${clockCalls}; unsupported font and missing hook rejected`);
}
