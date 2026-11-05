#!/usr/bin/env python3
"""Generate the D3D12 glass shader and shared SDF clip math from Metal.

The glass material is still being refit against native measurements; a hand
port drifted 14 commits behind Metal and Windows rendered the superseded model.
The HLSL is therefore generated from the Metal source and checked in, and
`--check` fails when the checked-in file no longer matches its generator.

This is a source-to-source translation for the subset of Metal Shading Language
that glass.metal uses, not a general MSL compiler. Unsupported constructs raise
instead of being passed through, so a new Metal idiom stops the check rather
than silently producing a different shader.

usage: tools/metal_to_hlsl.py [--check]
"""
import hashlib
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "src/render/shaders/glass.metal"
OUTPUT = REPO / "src/gpu/d3d12/shaders/glass.hlsl"
SDF_SOURCE = REPO / "src/render/shaders/sdf_primitives.metal"
SDF_OUTPUT = REPO / "src/gpu/d3d12/shaders/sdf_primitives.hlsl"
# blur.metal binds several uniform layouts at buffer(0) and packs a float array,
# which a cbuffer cannot express directly; it is ported by hand. The port
# records the hash of the Metal source it matches, so a Metal change still
# fails --check until the port is updated.
BLUR_SOURCE = REPO / "src/render/shaders/blur.metal"
BLUR_PORT = REPO / "src/gpu/d3d12/shaders/blur.hlsl"
BLUR_HASH_TAG = "// ported-from-metal-sha256: "

UNIFORM_TYPE = "GlassUniforms"
UNIFORM_NAME = "u"
VERTEX_ENTRY = "glass_vertex_main"
FRAGMENT_ENTRY = "glass_fragment_main"


METAL_CONSTANTS = {
    "M_PI_F": "3.14159265358979323846",
    "M_PI_2_F": "1.57079632679489661923",
    "M_SQRT2_F": "1.41421356237309504880",
    "M_SQRT1_2_F": "0.70710678118654752440",
}


class TranslationError(Exception):
    pass


def blank(text):
    """Same-length copy of text with comments replaced by spaces."""
    return "".join(text[s:e] if code else re.sub(r"[^\n]", " ", text[s:e])
                   for s, e, code in code_spans(text))


def match_paren(text, open_index):
    """Index of the bracket closing text[open_index] (one of '(' '[' '{'), ignoring comments."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    text = blank(text)
    opener = text[open_index]
    closer = pairs[opener]
    depth = 0
    i = open_index
    while i < len(text):
        ch = text[i]
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise TranslationError(f"unbalanced {opener} at offset {open_index}")


def split_args(text):
    """Split a comma-separated argument list at top level."""
    args, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:i])
            start = i + 1
    args.append(text[start:])
    return args


def code_spans(text):
    """Yield (start, end, is_code) spans, separating comments from code."""
    i, start = 0, 0
    while i < len(text):
        if text.startswith("//", i) or text.startswith("/*", i):
            if start < i:
                yield start, i, True
            end = text.find("\n", i) if text.startswith("//", i) else text.index("*/", i) + 2
            end = len(text) if end < 0 else end
            yield i, end, False
            i = start = end
            continue
        i += 1
    if start < len(text):
        yield start, len(text), True


def map_code(text, fn):
    return "".join(fn(text[s:e]) if code else text[s:e] for s, e, code in code_spans(text))


def rewrite_calls(text, name, rewrite):
    """Replace every `name(args)` call with rewrite(args).

    Matches are collected once and rewritten last-to-first: a nested call
    starts after its enclosing call, so rewriting it never moves an earlier
    match, and rewritten output is never matched again.
    """
    pattern = re.compile(r"(?<![\w.])" + re.escape(name) + r"\s*\(")
    for m in reversed(list(pattern.finditer(blank(text)))):
        open_index = m.end() - 1
        close = match_paren(text, open_index)
        replacement = rewrite(split_args(text[open_index + 1:close]))
        text = text[:m.start()] + replacement + text[close + 1:]
    return text


def strip_comments(text):
    return "".join(text[s:e] for s, e, code in code_spans(text) if code)


def parse_structs(text):
    """name -> [(type, field)] for plain structs (used for brace construction)."""
    structs = {}
    for m in re.finditer(r"\bstruct\s+(\w+)\s*\{", text):
        close = match_paren(text, m.end() - 1)
        body = strip_comments(text[m.end():close])
        fields = []
        for decl in body.split(";"):
            decl = decl.strip()
            if not decl:
                continue
            dm = re.fullmatch(r"(\w+)\s+([\w\s,]+?)(\s*\[\[\w+\]\])?", decl)
            if not dm:
                continue
            for field in dm.group(2).split(","):
                fields.append((dm.group(1), field.strip()))
        structs[m.group(1)] = fields
    return structs


def translate(metal):
    text = metal
    text = text.replace("#include <metal_stdlib>\n", "").replace("using namespace metal;\n", "")
    for banned in ("thread ", "device ", "threadgroup ", "[[buffer", "half2", "half3", "half4", "as_type", "discard_fragment ("):
        if banned in strip_comments(text) and not banned.startswith("[[buffer"):
            raise TranslationError(f"unsupported Metal construct: {banned!r}")

    structs = parse_structs(text)

    # Helper functions that receive the uniforms by reference read the global
    # cbuffer instead; drop the parameter and the matching call argument. A
    # by-value copy would turn the dynamically indexed shape arrays into
    # indexable temporaries.
    uniform_param = re.compile(r"\s*constant\s+" + UNIFORM_TYPE + r"\s*&\s*" + UNIFORM_NAME + r"\s*")
    dropped = {}
    for m in re.finditer(r"\b(\w+)\s+(\w+)\s*\(", blank(text)):
        name = m.group(2)
        if name in ("if", "for", "while", "switch", "return") or m.group(1) in ("return", "else"):
            continue
        open_index = m.end() - 1
        close = match_paren(text, open_index)
        after = text[close + 1:close + 40].lstrip()
        if not after.startswith("{"):
            continue
        args = split_args(text[open_index + 1:close])
        for index, arg in enumerate(args):
            if uniform_param.fullmatch(strip_comments(arg)) or (
                    strip_comments(arg).strip().startswith("constant " + UNIFORM_TYPE) and "[[buffer(0)]]" in arg):
                dropped[name] = index
    if not dropped:
        raise TranslationError("no uniform-taking helpers found; generator assumptions changed")

    def drop_param(signature_args, index):
        kept = [a for i, a in enumerate(signature_args) if i != index]
        return ",".join(kept).lstrip() if kept and kept[0].startswith(" ") else ",".join(kept)

    for name, index in dropped.items():
        # Definition (first occurrence followed by a body) and calls.
        def rewrite(args, name=name, index=index):
            if strip_comments(args[index]).strip() not in (UNIFORM_NAME,):
                # This is the definition; parameters are declarations.
                if UNIFORM_TYPE not in args[index]:
                    raise TranslationError(f"{name}: argument {index} is {args[index]!r}, expected {UNIFORM_NAME}")
            kept = [a for i, a in enumerate(args) if i != index]
            if kept:
                kept[0] = kept[0].lstrip() if index == 0 else kept[0]
            return f"{name}(" + ",".join(kept) + ")"
        text = rewrite_calls(text, name, rewrite)

    # Entry points.
    vm = re.search(r"vertex\s+(\w+)\s+" + VERTEX_ENTRY + r"\s*\(", text)
    if not vm:
        raise TranslationError("vertex entry not found")
    close = match_paren(text, vm.end() - 1)
    text = text[:vm.start()] + f"{vm.group(1)} {VERTEX_ENTRY}(uint vertex_id : SV_VertexID)" + text[close + 1:]

    fm = re.search(r"fragment\s+float4\s+" + FRAGMENT_ENTRY + r"\s*\(", text)
    if not fm:
        raise TranslationError("fragment entry not found")
    close = match_paren(text, fm.end() - 1)
    params = split_args(text[fm.end():close])
    resources = []
    stage_in = None
    for param in params:
        p = strip_comments(param).strip()
        if not p:
            continue
        tm = re.fullmatch(r"texture2d<float>\s+(\w+)\s*\[\[texture\((\d+)\)\]\]", p)
        sm = re.fullmatch(r"sampler\s+(\w+)\s*\[\[sampler\((\d+)\)\]\]", p)
        im = re.fullmatch(r"(\w+)\s+(\w+)\s*\[\[stage_in\]\]", p)
        # A read-only float4 table in a fragment buffer (set once from Zig): a structured buffer
        # at t<slot> in space 0 (the backends' fragment buffer slot, as icon.hlsl's instances).
        bm = re.fullmatch(r"constant\s+float4\s*\*\s*(\w+)\s*\[\[buffer\(([1-9]\d*)\)\]\]", p)
        if bm:
            resources.append(f"StructuredBuffer<float4> {bm.group(1)} : register(t{bm.group(2)}, space0);")
        elif tm:
            resources.append(f"Texture2D<float4> {tm.group(1)} : register(t{tm.group(2)}, space1);")
        elif sm:
            resources.append(f"SamplerState {sm.group(1)} : register(s{sm.group(2)}, space2);")
        elif im:
            stage_in = (im.group(1), im.group(2))
        elif p.startswith("constant " + UNIFORM_TYPE):
            continue
        else:
            raise TranslationError(f"unsupported fragment parameter: {p!r}")
    if stage_in is None:
        raise TranslationError("fragment stage_in parameter not found")
    text = text[:fm.start()] + f"float4 {FRAGMENT_ENTRY}({stage_in[0]} {stage_in[1]}) : SV_Target" + text[close + 1:]

    # Resource declarations follow the uniform struct.
    sm = re.search(r"\bstruct\s+" + UNIFORM_TYPE + r"\s*\{", text)
    end = match_paren(text, sm.end() - 1)
    semi = text.index(";", end)
    bindings = "\n".join([f"cbuffer {UNIFORM_TYPE}Buffer : register(b0, space0) {{ {UNIFORM_TYPE} {UNIFORM_NAME}; }};"] + resources)
    text = text[:semi + 1] + "\n" + bindings + "\n" + text[semi + 1:]

    def code(s):
        # Vertex output attributes.
        s = re.sub(r"(\bfloat4\s+\w+)\s*\[\[position\]\]", r"\1 : SV_Position", s)
        s = re.sub(r"\[\[\w+(\(\d+\))?\]\]", lambda m: (_ for _ in ()).throw(TranslationError(f"attribute left: {m.group(0)}")), s)
        # Loops Metal marks GLASS_ROLLED_LOOP stay rolled in HLSL (see glass.metal).
        s = s.replace("#define GLASS_ROLLED_LOOP\n", "#define GLASS_ROLLED_LOOP [loop]\n")
        # Helpers take the fragment buffer's table as a parameter (Metal has no global buffers).
        s = re.sub(r"\bconstant\s+float4\s*\*\s*(?=\w)", "StructuredBuffer<float4> ", s)
        s = re.sub(r"\bconstant\s+(?=(float|int|uint|bool)\d?\s)", "static const ", s)
        if re.search(r"\bconstant\b", s):
            raise TranslationError("unhandled `constant` qualifier")
        s = re.sub(r"\bstatic\s+inline\s+", "", s)
        s = re.sub(r"\binline\s+", "", s)
        s = re.sub(r"\btexture2d<float>\s+", "Texture2D<float4> ", s)
        s = re.sub(r"\bsampler\s+(?=\w)", "SamplerState ", s)
        s = re.sub(r"\bmix\s*\(", "lerp(", s)
        s = re.sub(r"\bfract\s*\(", "frac(", s)
        # Metal derivatives are per-pixel (fine). HLSL ddx/ddy/fwidth may be
        # coarse (one difference per 2x2 quad, as WARP does), which shifts
        # antialiased edge coverage asymmetrically; request fine explicitly.
        s = re.sub(r"\bdfdx\s*\(", "ddx_fine(", s)
        s = re.sub(r"\bdfdy\s*\(", "ddy_fine(", s)
        s = re.sub(r"\bfwidth\s*\(", "zenit_fwidth(", s)
        s = re.sub(r"\.sample\s*\(", ".SAMPLE_LEVEL(", s)
        s = re.sub(r"\bdiscard_fragment\s*\(\s*\)", "discard", s)
        # `in` / `out` are HLSL parameter qualifiers.
        s = re.sub(r"\bin\b", "vin", s)
        s = re.sub(r"\bout\b", "vout", s)
        return s

    text = map_code(text, code)

    # Interpolants of the stage-in struct need semantics.
    vs = re.search(r"\bstruct\s+" + stage_in[0] + r"\s*\{", text)
    body_end = match_paren(text, vs.end() - 1)
    body, slot = [], 0
    for line in text[vs.end():body_end].split("\n"):
        lm = re.fullmatch(r"(\s*\w+\s+\w+)\s*;(.*)", line)
        if lm and ":" not in lm.group(1):
            line = f"{lm.group(1)} : TEXCOORD{slot};{lm.group(2)}"
            slot += 1
        body.append(line)
    text = text[:vs.end()] + "\n".join(body) + text[body_end:]

    # Texture sampling: no mips anywhere in the glass inputs, and implicit-LOD
    # sampling is invalid in the divergent loops this shader uses.
    text = re.sub(r"\.SAMPLE_LEVEL\(", ".SampleLevel(", text)
    text = fix_sample_level(text)

    # select(a, b, c) == c ? b : a, component-wise.
    text = rewrite_calls(text, "select", lambda a: f"(({a[2].strip()}) ? ({a[1].strip()}) : ({a[0].strip()}))" if len(a) == 3 else bad("select", a))
    # Scalar splat constructors.
    for vec in ("float2", "float3", "float4", "int2", "int3", "int4", "uint2", "uint3", "uint4"):
        text = rewrite_calls(text, vec, lambda a, vec=vec: f"(({vec})({a[0].strip()}))" if len(a) == 1 else f"{vec}(" + ",".join(a) + ")")
    # Brace construction of plain structs.
    for name, fields in structs.items():
        pattern = re.compile(r"(?<!struct )\b" + name + r"\s*\{")
        if not pattern.search(strip_comments(text)):
            continue
        text = pattern.sub(f"make_{name}(", text)
        text = close_brace_constructors(text, f"make_{name}(")
        params = ", ".join(f"{t} {f}" for t, f in fields)
        assigns = " ".join(f"r.{f} = {f};" for _, f in fields)
        ctor = f"{name} make_{name}({params}) {{ {name} r; {assigns} return r; }}\n"
        sdef = re.search(r"\bstruct\s+" + name + r"\s*\{", text)
        end = text.index(";", match_paren(text, sdef.end() - 1))
        text = text[:end + 1] + "\n" + ctor + text[end + 1:]

    text = re.sub(r"\blength_squared\s*\(", "zenit_length_squared(", text)
    constants = ""
    for name in sorted(set(re.findall(r"\bM_[A-Z0-9_]+_F\b", strip_comments(text)))):
        if name not in METAL_CONSTANTS:
            raise TranslationError(f"unknown Metal constant {name}")
        constants += f"static const float {name} = {METAL_CONSTANTS[name]};\n"
    helpers = constants + (
        "float zenit_length_squared(float2 v) { return dot(v, v); }\n"
        "float zenit_fwidth(float v) { return abs(ddx_fine(v)) + abs(ddy_fine(v)); }\n"
        "float2 zenit_fwidth(float2 v) { return abs(ddx_fine(v)) + abs(ddy_fine(v)); }\n"
        "float zenit_length_squared(float3 v) { return dot(v, v); }\n"
    )
    header = (
        "// GENERATED by tools/metal_to_hlsl.py from src/render/shaders/glass.metal.\n"
        "// Do not edit; change the Metal source and regenerate.\n"
        f"// zenit-entry: vertex {VERTEX_ENTRY}\n"
        f"// zenit-entry: fragment {FRAGMENT_ENTRY}\n"
    )
    first_fn = re.search(r"^\w[\w<>]*\s+\w+\s*\(", text, re.M)
    text = text[:first_fn.start()] + helpers + "\n" + text[first_fn.start():]
    return header + text.lstrip("\n")


def bad(name, args):
    raise TranslationError(f"{name}: unexpected arguments {args!r}")


def fix_sample_level(text):
    def rewrite(args):
        if len(args) != 2:
            raise TranslationError(f"sample: unexpected arguments {args!r}")
        return ".SampleLevel(" + ",".join(args) + ", 0)"
    pattern = re.compile(r"\.SampleLevel\(")
    out, i = [], 0
    for m in pattern.finditer(text):
        if m.start() < i:
            continue
        close = match_paren(text, m.end() - 1)
        out.append(text[i:m.start()])
        out.append(rewrite(split_args(text[m.end():close])))
        i = close + 1
    out.append(text[i:])
    return "".join(out)


def close_brace_constructors(text, marker):
    out, i = [], 0
    while True:
        j = text.find(marker, i)
        if j < 0:
            out.append(text[i:])
            return "".join(out)
        start = j + len(marker)
        depth, k = 1, start
        while depth:
            if text[k] in "({[":
                depth += 1
            elif text[k] in ")}]":
                depth -= 1
            k += 1
        if text[k - 1] != "}":
            raise TranslationError("brace constructor closed by a non-brace")
        # Brace initializers may end with a trailing comma; calls may not.
        out.append(text[i:start] + re.sub(r",(\s*)$", r"\1", text[start:k - 1]) + ")")
        i = k


def translate_sdf_clip(metal, hlsl):
    """The remaining Windows SDF material/vertex adapter is a hand port.

    Own the shared clip functions, uniform flag and their two Windows call sites;
    leave the platform-specific material and tiled-vertex entries intact.
    """
    begin = "// sdf-clip-shared-begin (also generated into HLSL)"
    end = "// sdf-clip-shared-end"
    shared = metal[metal.index(begin):metal.index(end) + len(end)]
    shared = shared.replace(begin, "// sdf-clip-shared-begin (generated by tools/metal_to_hlsl.py; do not edit)")
    shared = re.sub(r"fwidth\((\w+)\)", r"(abs(ddx_fine(\1)) + abs(ddy_fine(\1)))", shared)
    # Also accepts the legacy hand-port layout for the initial migration.
    start = hlsl.find("// sdf-clip-shared-begin")
    if start < 0:
        start = hlsl.index("float rect_clip_alpha(")
    stop = hlsl.index("float shape_clip_alpha(", start)
    hlsl = hlsl[:start] + shared + "\n\n" + hlsl[stop:]
    flag = "    uint raster_clip_pos; // Raster pixel centers when viewport matches SDF coordinates\n"
    if flag.strip() not in metal:
        raise TranslationError("missing Metal SDF raster clip uniform")
    hlsl, count = re.subn(r"(    uint frame_seed;[^\n]*\n)(?:    uint raster_clip_pos;[^\n]*\n)?",
                         lambda m: m[1] + flag, hlsl, count=1)
    if count != 1:
        raise TranslationError("missing HLSL SDF frame seed uniform")
    # The adapter's SV_Position is a raster position in fragment entries.
    pos = "sdf_clip_screen_pos(input.position.xy, input.screen_pos, uniforms.raster_clip_pos)"
    for fn, uniform in (("clip_alpha", "clip_uniforms"), ("rect_clip_alpha", "uniforms.scale_factor")):
        pattern = (rf"{fn}\((?:input.screen_pos|sdf_clip_screen_pos\(input.position.xy, "
                   rf"input.screen_pos, uniforms.raster_clip_pos\)), input.rect_clip, {re.escape(uniform)}\)")
        hlsl, count = re.subn(pattern, f"{fn}({pos}, input.rect_clip, {uniform})", hlsl)
        if count != 1:
            raise TranslationError(f"expected one SDF adapter call to {fn}, found {count}")
    return hlsl


def main(argv):
    check = argv[1:] == ["--check"]
    if argv[1:] and not check:
        print(__doc__, file=sys.stderr)
        return 64
    generated = translate(SOURCE.read_text())
    sdf_original = SDF_OUTPUT.read_text()
    sdf_generated = translate_sdf_clip(SDF_SOURCE.read_text(), sdf_original)
    blur_hash = hashlib.sha256(BLUR_SOURCE.read_bytes()).hexdigest()
    blur_port = BLUR_PORT.read_text()
    recorded = [line[len(BLUR_HASH_TAG):].strip() for line in blur_port.splitlines() if line.startswith(BLUR_HASH_TAG)]
    if check:
        status = 0
        if OUTPUT.read_text() != generated:
            print(f"{OUTPUT.relative_to(REPO)} is stale; run tools/metal_to_hlsl.py", file=sys.stderr)
            status = 1
        if sdf_original != sdf_generated:
            print(f"{SDF_OUTPUT.relative_to(REPO)} shared clip math is stale; run tools/metal_to_hlsl.py", file=sys.stderr)
            status = 1
        if recorded != [blur_hash]:
            print(f"{BLUR_SOURCE.relative_to(REPO)} changed since {BLUR_PORT.relative_to(REPO)} was ported; "
                  f"port the change, then record sha256 {blur_hash}", file=sys.stderr)
            status = 1
        return status
    OUTPUT.write_text(generated)
    SDF_OUTPUT.write_text(sdf_generated)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
