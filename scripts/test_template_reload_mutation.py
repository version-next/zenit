#!/usr/bin/env python3
"""Serial behavioral mutations, frozen inputs, exact restoration; no GUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
from test_component_view_mutation import inventory, is_compile_failure
ROOT = Path(__file__).resolve().parents[1]
# Candidate hook mutations also exercise target invalidation before publication.
MUTANTS = (
    ('lp5_deinit_publishing_cleanup', 'src/ui/template_reload.zig',
     'if (publishing) commit_reentered = true;',
     'if (publishing) { commit_reentered = true; return; }'),
    ('lp5_portal_lease', 'src/ui/view.zig',
     'mounted.has_lease = true;',
     'mounted.root.lease.release(); mounted.root = .{ .node = n }; mounted.has_lease = false;'),
    ('lp5_branch_set_fallback', 'src/ui/template_reload.zig',
     'if (before_components.len != after_components.len) {\n                p.result = .{ .fallback = .{ .file = path, .reason = "TemplateRegionSetChanged" } };',
     'if (before_components.len != after_components.len) {\n                p.result = .ready;'),
    ('lp5_new_factory_fallback', 'src/ui/template_reload.zig',
     'p.result = .{ .fallback = .{ .file = path, .reason = @errorName(err) } };',
     'p.result = if (err == error.TemplateHoleChanged) .ready else .{ .fallback = .{ .file = path, .reason = @errorName(err) } };'),
    ('builder_identity', 'src/ui/view.zig',
     'if (comptime PreviewFunctionIdentity(builder) != PreviewFunctionIdentity(P.__yix_preview_builder)) return error.TemplateCandidateSideEffects;', '{}'),
    ('mount_identity', 'src/ui/view.zig',
     'if (comptime PreviewFunctionIdentity(f) != PreviewFunctionIdentity(Props.__yix_preview_mount)) return error.TemplateCandidateSideEffects;', '{}'),
    ('candidate_first_mount', 'src/ui/preview_mount.zig',
     'const tx = current orelse return false;', 'const tx = current orelse return false; if (kind == .mount and tx.actions.items.len == 0) return false;'),
    ('hover_subscription', 'src/ui/hooks.zig',
     '''_ = try @import("preview_mount.zig").deferAction(scope, .subscription, listener, struct {
            fn attach(l: *HoverListener, _: *Scope) anyerror!void {
                const n = l.node orelse return;
                l.unqueue();
                // Earlier queued subscriptions have now published. Chain in mount
                // order rather than retaining the candidate-time list head.
                assertHoverHandlers(n);
                l.next = HoverListener.head(n);
                if (l.next) |p| if (p.owner != l.owner) return error.HoverOwnerMismatch;
                l.on_hover = if (l.next) |p| p.on_hover else n.behavior.events.on_hover;
                l.on_leave = if (l.next) |p| p.on_leave else n.behavior.events.on_leave;
                HoverListener.publish(n, l, null, null);
            }
        }.attach);''',
     'listener.unqueue(); listener.next = previous; HoverListener.publish(node, listener, null, null);'),
    ('focus_ring_subscription', 'src/ui/hooks.zig',
     '''_ = try @import("preview_mount.zig").deferAction(scope, .subscription, ring_ctx, struct {
                fn attach(c: *FocusRingCtx, _: *Scope) anyerror!void {
                    if (c.node == null) return;
                    c.subscription_id = try c.fm.subscribeVisibility(c, focusRingVisibilityChanged);
                }
            }.attach);''',
     'ring_ctx.subscription_id = try cx.focus_manager.subscribeVisibility(ring_ctx, focusRingVisibilityChanged);'),
    ('hover_highlight_registration', 'src/ui/hooks.zig',
     '''if (!try @import("preview_mount.zig").deferAction(scope, .subscription, hl_state, struct {
            fn attach(state: *HoverHighlightState, _: *Scope) anyerror!void {
                const n = state.target_node orelse return;
                n.addBeforeRender(hoverHighlightBeforeRender);
            }
        }.attach)) target_node.addBeforeRender(hoverHighlightBeforeRender);''',
     'target_node.addBeforeRender(hoverHighlightBeforeRender);'),
    ('focus_ring_registration', 'src/ui/hooks.zig',
     '''if (!try @import("preview_mount.zig").deferAction(scope, .subscription, anim_state, struct {
            fn attach(state: *FocusRingAnimState, _: *Scope) anyerror!void {
                const n = state.node orelse return;
                n.addBeforeRenderScoped(focusRingBeforeRender, .self);
            }
        }.attach)) node.addBeforeRenderScoped(focusRingBeforeRender, .self);''',
     'node.addBeforeRenderScoped(focusRingBeforeRender, .self);'),
    ('child_relocation', 'src/ui/template.zig',
     'if (!componentReceiver(hole.receiver.name)) return false;',
     'if (!componentReceiver(hole.receiver.name) and !std.mem.eql(u8, hole.receiver.name, "control")) return false;'),
    ('lp5_instance_match', 'src/ui/view.zig',
     'if (child.caller != old or !template.holeEqual(child.hole, hole)) continue;',
     'if (child.caller != old or (hole.site == 0 and !template.holeEqual(child.hole, hole))) continue;'),
    ('lp5_reused_state', 'src/ui/view.zig',
     'child.caller = self.destination;',
     'child.caller = self.destination; if (instance.setup.signals.items.len > 0) { const signal: *reactive.Signal(u32) = @ptrCast(@alignCast(instance.setup.signals.items[0])); signal.set(0); }'),
    ('lp5_control_state', 'src/ui/template_reload.zig',
     '!eq(a.identity_tokens orelse a.tokens, b.identity_tokens orelse b.tokens)',
     '!eq(a.tokens, b.tokens)'),
    ('lp5_nested_getter', 'src/ui/template.zig',
     'if (comptime @hasField(T, "cond")) if (!safeData(value.cond)) return false;',
     'if (comptime @hasField(T, "cond")) if (false and !safeData(value.cond)) return false;'),
    ('lp5_capture_lifetime', 'src/ui/view.zig',
     'if (!child.validate_context(child.context, scope)) return error.TemplateRetainedCaptureLifetime;',
     'if (false and !child.validate_context(child.context, scope)) return error.TemplateRetainedCaptureLifetime;'),
    ('lp5_borrowed_storage', 'src/ui/template.zig',
     'if (comptime @typeInfo(T) == .pointer) return if (@typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.sentinel_ptr == null) value.len == 0 else false;',
     'if (comptime @typeInfo(T) == .pointer) return safeData(value);'),
    ('lp5_literal_provenance', 'src/ui/template.zig',
     'return value.ptr == literal.text.ptr and value.len == literal.text.len;',
     'return std.mem.eql(u8, value, literal.text);'),
    ('lp5_empty_sentinel', 'src/ui/template.zig',
     '@typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.sentinel_ptr == null',
     '@typeInfo(T).pointer.size == .slice'),
    ('lp5_slot_region', 'src/ui/template.zig',
     'slot_region_pending = comptime singleSlotSite(@TypeOf(content));',
     'slot_region_pending = false;'),
    ('candidate_side_effect', 'src/ui/preview_mount.zig',
     'const tx = current orelse return false;', 'const tx = current orelse return false; if (kind == .ref) return false;'),
    ('commit_order', 'src/ui/preview_mount.zig',
     'for (self.actions.items, 0..) |action, index| {',
     'for (0..self.actions.items.len) |index| { const action = self.actions.items[self.actions.items.len - 1 - index];'),
    ('commit_l3', 'src/ui/template_reload.zig',
     'requestRemount(commit_error);', 'if (commit_error.len == 0) requestRemount(commit_error);'),
    ('classifier', 'src/ui/template_reload.zig',
     '!eq(old.envelope, next.envelope) or old.components.len != next.components.len',
     'old.components.len != next.components.len'),
    ('rollback', 'src/ui/view.zig',
     'if (self.consumed) return;', 'if (self.consumed or !self.consumed) return;'),
    ('state_reset', 'src/ui/view.zig',
     'if (was_root) cx.root = root;',
     'if (was_root) cx.root = root;\n        if (i.setup.signals.items.len > 0) { const signal: *reactive.Signal(u32) = @ptrCast(@alignCast(i.setup.signals.items[0])); signal.set(0); }'),
    ('early_capture_guard', 'src/ui/view.zig', 'try template.validatePreviewContext(c.*);', '{}'),
    ('owner_alias_guard', 'src/ui/view.zig', 'if (!transactionOwnerSafe(cx, old)) return error.ViewTransactionUnsupported;', '{}'),
    ('generation', 'src/ui/template_reload.zig', 'generation += 1;', 'generation += 2;'),
    ('generation_retirement', 'src/ui/template_reload.zig',
     'var retired = previous.next;', 'var retired: ?*Preparation = null;'),
    ('catalog_omission', 'src/ui/template.zig',
     'return T.template_site.catalog.styles;', 'return &.{};'),
    ('fragment_routing', 'src/ui/template_reload.zig',
     'instruction.fragments = op.fragments;', 'instruction.fragments = &.{};'),
    ('literal_routing', 'src/ui/template_reload.zig',
     '.boolean = false } else return error.TemplateLiteralUnsupported', '.boolean = true } else return error.TemplateLiteralUnsupported'),
    ('format_subscription', 'src/ui/template.zig',
     'if (comptime @typeInfo(@TypeOf(value)) == .pointer and has(@typeInfo(@TypeOf(value)).pointer.child, "zenit_reactive")) return value.get();',
     'if (comptime @typeInfo(@TypeOf(value)) == .pointer and has(@typeInfo(@TypeOf(value)).pointer.child, "zenit_reactive")) return value.peek();'),
    ('hole_multiset', 'src/ui/template.zig', 'a.occurrence != b.occurrence or ', ''),
)
def detected(code, output):
    return code > 0 and not is_compile_failure(output) and re.search(r'FAIL \(Test\w+\)', output) is not None and not re.search(r'panic:|test crashed|timed out', output, re.I)
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig'); parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args(); args.evidence.mkdir(parents=True, exist_ok=True)
    report = dict(mutants=[], source_restored=False); child = None; pending = None
    originals = {ROOT/path:(ROOT/path).read_bytes() for _, path, _, _ in MUTANTS}
    erasure_path = ROOT/'examples/template_probe/main.zig'
    originals[erasure_path] = erasure_path.read_bytes()
    def run_command(argv, name):
        nonlocal child
        with (args.evidence/(name+'.log')).open('w') as log:
            child = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            code = child.wait(timeout=600)
        return code, (args.evidence/(name+'.log')).read_text()
    def run(name):
        nonlocal child
        with (args.evidence/(name+'.log')).open('w') as log:
            child = subprocess.Popen([args.zig, 'build', 'test-template-reload', '-j1'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            code = child.wait(timeout=600)
        return code, (args.evidence/(name+'.log')).read_text()
    previous = {}
    def interrupted(signum, _): raise KeyboardInterrupt(f'signal {signum}')
    for name in ('SIGTERM', 'SIGHUP'):
        sig = getattr(signal, name); previous[sig] = signal.signal(sig, interrupted)
    try:
        code, _ = run('baseline'); report['baseline_exit'] = code
        if code: raise RuntimeError('baseline gate failed')
        for name, relative, needle, replacement in MUTANTS:
            path = ROOT/relative; source = originals[path].decode()
            if source.count(needle) != 1: raise RuntimeError(name+': stale mutation anchor')
            frozen = inventory(ROOT, path)
            mutated = source.replace(needle, replacement).encode()
            pending = (path, mutated); path.write_bytes(mutated)
            code, output = run(name)
            if inventory(ROOT, path) != frozen: raise RuntimeError(name+': concurrent input drift')
            if path.read_bytes() != mutated: raise RuntimeError(name+': concurrent target change')
            path.write_bytes(originals[path]); pending = None
            report['mutants'].append(dict(name=name, mutant_exit=code, detected=detected(code, output),
                runtime_assertions=re.findall(r'FAIL \((Test\w+)\)', output),
                inputs_sha256=hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest()))
            print(json.dumps(report['mutants'][-1]), flush=True)
        # Contaminate a real production binary with an exported queue symbol.
        # The erasure scanner must reject it; compile errors never count.
        frozen = inventory(ROOT, erasure_path)
        main_entry = b'pub fn main(init: std.process.Init) !void {'
        if originals[erasure_path].count(main_entry) != 1: raise RuntimeError('erasure main anchor changed')
        mutated = originals[erasure_path].replace(main_entry, main_entry + b'\n    @call(.never_inline, lp4_preview_mount_erasure_mutant, .{});')
        mutated += b'\nexport fn lp4_preview_mount_erasure_mutant() void { std.debug.print("intentional erasure mutation\\n", .{}); }\n'
        pending = (erasure_path, mutated); erasure_path.write_bytes(mutated)
        code, _ = run_command([args.zig, 'build', 'template-probe-exe', '-Doptimize=safe', '-Ddev-preview=false', '-j1'], 'erasure-build')
        if code: raise RuntimeError('erasure mutation did not compile')
        code, output = run_command(['python3', 'scripts/check_template_reload_erasure.py', 'zig-out/bin/template_probe', '--output', str(args.evidence.resolve()/'erasure-symbols.json')], 'erasure-scan')
        symbols = json.loads((args.evidence/'erasure-symbols.json').read_text())
        if inventory(ROOT, erasure_path) != frozen or erasure_path.read_bytes() != mutated: raise RuntimeError('erasure: concurrent input drift')
        erasure_path.write_bytes(originals[erasure_path]); pending = None
        report['mutants'].append(dict(name='release_erasure', mutant_exit=code, detected=code == 1 and symbols['lp4_symbols'] > 0, symbols=symbols['lp4_symbols']))
        report['restored_exit'], _ = run('restored')
    except BaseException as exc: report['error'] = f'{type(exc).__name__}: {exc}'
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
        if pending is not None:
            path, mutated = pending
            if path.read_bytes() == mutated: path.write_bytes(originals[path])
            else: report['restore_error'] = 'concurrent target change preserved'
        report['source_restored'] = all(path.read_bytes() == data for path, data in originals.items())
        for sig, handler in previous.items(): signal.signal(sig, handler)
        (args.evidence/'result.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)
    return 0 if report.get('baseline_exit') == report.get('restored_exit') == 0 and report['source_restored'] and len(report['mutants']) == len(MUTANTS) + 1 and all(m['detected'] for m in report['mutants']) and 'error' not in report else 1
if __name__ == '__main__': raise SystemExit(main())
