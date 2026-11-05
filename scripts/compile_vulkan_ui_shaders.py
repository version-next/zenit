#!/usr/bin/env python3
"""Compile the shared HLSL ports to validated Vulkan SPIR-V and a Zig manifest.

The Windows programs already use explicit register spaces. Vulkan preserves
those sets/bindings, but SV_VertexID/SV_InstanceID include the draw base: remove
Windows' extra base-index cbuffer to avoid adding the offset twice. Invert clip
Y for Vulkan's positive-height viewport; logical UI coordinates stay unchanged.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path


def descriptor_bindings(binary):
    words = struct.unpack('<%dI' % (len(binary) // 4), binary)
    if len(words) < 5 or words[0] != 0x07230203:
        raise ValueError('invalid SPIR-V header')
    decorations, member_decorations, types, constants, variables = {}, {}, {}, {}, []
    i = 5
    while i < len(words):
        count, op = words[i] >> 16, words[i] & 65535
        if not count or i + count > len(words):
            raise ValueError('invalid SPIR-V instruction length')
        args = words[i + 1:i + count]
        if op == 71:  # OpDecorate
            decorations.setdefault(args[0], {})[args[1]] = args[2:]
        elif op == 72:  # OpMemberDecorate
            member_decorations.setdefault((args[0], args[1]), {})[args[2]] = args[3:]
        elif op in (20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32):
            types[args[0]] = (op, args[1:])
        elif op == 43:  # OpConstant (array lengths in the UI ABI are u32)
            constants[args[1]] = args[2:]
        elif op == 59:  # OpVariable: result type, result id, storage class
            variables.append(args[:3])
        i += count
    def byte_size(type_id, member=None):
        op, args = types[type_id]
        if op == 20:
            return 4
        if op in (21, 22):
            return args[0] // 8
        if op == 23:
            return byte_size(args[0]) * args[1]
        if op == 24:
            dec = member_decorations.get(member, {})
            if 7 not in dec:
                raise ValueError('uniform matrix lacks MatrixStride')
            columns = args[1]
            rows = types[args[0]][1][1]
            return dec[7][0] * (rows if 4 in dec else columns)
        if op == 28:
            length = constants.get(args[1])
            stride = decorations.get(type_id, {}).get(6)
            if not length or len(length) != 1 or not stride:
                raise ValueError('uniform array has unverified length/stride')
            return length[0] * stride[0]
        if op == 29:
            return 0  # fixed prefix; runtime storage data checked by the draw
        if op == 30:
            size = 0
            for index, field_type in enumerate(args):
                key = (type_id, index)
                offset = member_decorations.get(key, {}).get(35)
                if not offset:
                    raise ValueError('uniform/storage member lacks Offset')
                size = max(size, offset[0] + byte_size(field_type, key))
            return size
        raise ValueError('unsupported uniform member type %s' % op)

    result = []
    for ptr, var, storage in variables:
        dec = decorations.get(var, {})
        if 33 not in dec or 34 not in dec:
            continue
        group, binding = dec[34][0], dec[33][0]
        op, args = types[ptr]
        if op != 32:
            raise ValueError('descriptor variable must have pointer type')
        pointee = args[1]
        op, args = types[pointee]
        if storage in (2, 12) and op == 30:
            kind = 2 if storage == 12 or 3 in decorations.get(pointee, {}) else 0
        elif storage == 0 and op == 25 and args[5] == 1:
            kind = 1  # separate sampled image
        elif storage == 0 and op == 26:
            kind = 4  # separate sampler
        else:
            raise ValueError('unsupported descriptor type/storage: %s/%s' % (op, storage))
        if group >= 4:
            raise ValueError('descriptor set exceeds renderer contract: %d' % group)
        if any(r['group'] == group and r['binding'] == binding for r in result):
            raise ValueError('duplicate descriptor binding')
        min_size, stride = 0, 0
        if kind in (0, 2):
            min_size = byte_size(pointee)
            if kind == 0 and min_size == 0:
                raise ValueError('empty uniform descriptor block')
            if kind == 2:
                for field_type in types[pointee][1]:
                    if types[field_type][0] == 29:
                        stride = decorations.get(field_type, {}).get(6, [0])[0]
                        if not stride:
                            raise ValueError('storage array has no stride')
        result.append(dict(group=group, binding=binding, kind=kind, min_size=min_size, stride=stride))
    return sorted(result, key=lambda x: (x['group'], x['binding']))


def storage_layouts(binary):
    # Match the renderer's existing CPU structs, not a compiler-specific ABI.
    expected = {'PathVertexIn': 28, 'ImageInstanceData': 128,
                'GlyphInstance': 80, 'IconInstanceData': 64,
                'InstanceData': 176, 'ShadowParam': 32, 'GradientStop': 32}
    words = struct.unpack('<%dI' % (len(binary) // 4), binary)
    names, arrays, strides, types = {}, {}, {}, {}
    i = 5
    while i < len(words):
        count, op = words[i] >> 16, words[i] & 65535
        args = words[i + 1:i + count]
        if op == 5:  # OpName
            raw = struct.pack('<%dI' % (len(args) - 1), *args[1:])
            names[args[0]] = raw.split(b'\0', 1)[0].decode('utf8')
        elif op == 29:  # OpTypeRuntimeArray
            arrays[args[0]] = args[1]
        elif op in (22, 23):  # OpTypeFloat, OpTypeVector
            types[args[0]] = (op, args[1:])
        elif op == 71 and args[1] == 6:  # ArrayStride
            strides[args[0]] = args[2]
        i += count
    layouts = {}
    for array, element in arrays.items():
        name = names.get(element)
        # A bare float4 table (glass's tab lens field): the CPU's [4]f32 rows.
        vector = types.get(element)
        if name is None and vector and vector[0] == 23 and vector[1][1] == 4 and types.get(vector[1][0]) == (22, (32,)):
            name = 'float4'
            expected = dict(expected, float4=16)
        if name not in expected:
            raise ValueError('unverified CPU storage layout: %r' % name)
        stride = strides.get(array)
        if stride != expected[name]:
            raise ValueError('%s array stride %s does not match CPU stride %d' % (name, stride, expected[name]))
        layouts[name] = stride
    return layouts


def adapt_source(path, original):
    source, replacements = re.subn(
        r'cbuffer\s+ZenitDrawInfo\s*:\s*register\([^)]*\)\s*\{[^}]*\}\s*;',
        'static const uint first_vertex = 0; static const uint first_instance = 0;', original)
    if 'ZenitDrawInfo' in source or replacements > 1:
        raise ValueError('unrecognized draw-base declaration: %s' % path)
    # glslang pads these StructuredBuffer vectors differently from the CPU/D3D
    # structs. Scalars preserve the same values with the required byte layout.
    if path.stem == 'blur':
        # HLSL permits float3 at byte 20; std140 requires 16-byte alignment.
        # Unused padding scalars preserve the CPU's 32-byte area uniform ABI
        # and let the same validated SPIR-V translate to OpenGL.
        old = 'float3 area_padding;'
        if source.count(old) != 1:
            raise ValueError('unrecognized GaussianAreaUniforms padding')
        source = source.replace(old, 'float area_padding0; float area_padding1; float area_padding2;')
    if path.stem == 'glass':
        # glslang lowers HLSL logical-and to an eager load before OpLogicalAnd.
        # The insertion-sort sentinel therefore reads dist[-1] at j == 0,
        # even though the left operand is false. Keep that load in bounds;
        # the guarded sort body and its ordering remain unchanged.
        old = 'while (j > 0 && dist[j - 1] > d_i)'
        if source.count(old) != 1:
            raise ValueError('unrecognized glass insertion-sort sentinel')
        source = source.replace(old, 'while (j > 0 && dist[max(j - 1, 0)] > d_i)')
    if path.stem == 'path':
        old = 'struct PathVertexIn { float x; float y; float alpha_scale; float4 color; };'
        if source.count(old) != 1:
            raise ValueError('unrecognized PathVertexIn layout')
        source = source.replace(old, 'struct PathVertexIn { float x; float y; float alpha_scale; float color_r; float color_g; float color_b; float color_a; };')
        source = re.sub(r'\bv\.color\b', 'float4(v.color_r, v.color_g, v.color_b, v.color_a)', source)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--glslc', required=True)
    parser.add_argument('--spirv-val', required=True)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('sources', nargs='+', type=Path)
    opts = parser.parse_args()
    opts.out.mkdir(parents=True, exist_ok=True)
    records, names = [], set()
    zig = ['// Generated by compile_vulkan_ui_shaders.py; do not edit.',
           'pub const Stage = enum { vertex, fragment, compute };',
           'pub const Binding = struct { group: u32, binding: u32, kind: u32, min_size: u32, stride: u32 };',
           'pub const Entry = struct { program: []const u8, name: [:0]const u8, stage: Stage, code: []align(4) const u8, bindings: []const Binding };']
    for path in opts.sources:
        original = path.read_text()
        entries = re.findall(r'^// zenit-entry:\s*(vertex|fragment|compute)\s+(\w+)\s*$', original, re.M)
        if not entries:
            raise ValueError('missing entry manifest: %s' % path)
        source = adapt_source(path, original)
        adapted = opts.out / path.name
        adapted.write_text(source)
        for stage, entry in entries:
            if entry in names:
                raise ValueError('duplicate shader entry: %s' % entry)
            names.add(entry)
            output = opts.out / (entry + '.spv')
            command = [opts.glslc, '-x', 'hlsl', '--target-env=vulkan1.1', '-Werror', '-O', '-g',
                       '-fhlsl-offsets', '-fhlsl-iomap', '-fauto-map-locations', '-DZENIT_LINUX_GPU=1',
                       '-fshader-stage=' + stage, '-fentry-point=' + entry]
            if stage == 'vertex':
                command.append('-finvert-y')
            subprocess.run(command + [str(adapted), '-o', str(output)], check=True)
            subprocess.run([opts.spirv_val, '--target-env', 'vulkan1.1', str(output)], check=True)
            binary = output.read_bytes()
            bindings = descriptor_bindings(binary)
            layouts = storage_layouts(binary)
            record = dict(program=path.stem, name=entry, stage=stage, bindings=bindings, storage_layouts=layouts,
                          source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                          compiler_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
            records.append(record)
            zig.append('const %s align(4) = @embedFile("%s.spv").*;' % (entry, entry))
    zig.append('pub const entries = [_]Entry{')
    for record in records:
        binding_expr = ', '.join('.{ .group = %(group)d, .binding = %(binding)d, .kind = %(kind)d, .min_size = %(min_size)d, .stride = %(stride)d }' % b for b in record['bindings'])
        zig.append('    .{ .program = "%s", .name = "%s", .stage = .%s, .code = &%s, .bindings = &.{ %s } },' %
                   (record['program'], record['name'], record['stage'], record['name'], binding_expr))
    zig.append('};')
    (opts.out / 'shaders.zig').write_text('\n'.join(zig) + '\n')
    (opts.out / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
    print('VULKAN_UI_SHADERS PASS: programs=%d entries=%d spirv_validation=true' % (len(opts.sources), len(records)))


if __name__ == '__main__':
    main()
