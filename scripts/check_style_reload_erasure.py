#!/usr/bin/env python3
"""Inspect an unstripped release application, rejecting a vacuous empty symbol scan."""
import argparse
import json
from pathlib import Path
import re
import subprocess
p=argparse.ArgumentParser();p.add_argument('binary',type=Path);p.add_argument('--output',type=Path);args=p.parse_args()
r=subprocess.run(['nm',str(args.binary)],capture_output=True,text=True)
if r.returncode:raise SystemExit(r.stderr)
symbols=[line for line in r.stdout.splitlines() if line.strip()]
if len(symbols)<100:raise SystemExit('erasure gate requires an unstripped, nonempty symbol table')
pattern=re.compile(r'style_reload|theme_reload|previewCss|previewCva|styleGeneration|publishStyleGeneration|reload_styles|query_style|compileIR|style_signal',re.I)
found=[s for s in symbols if pattern.search(s)]
result=dict(binary=str(args.binary),symbols=len(symbols),dev_bridge_symbols=len(found),matches=found)
if args.output:args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result));raise SystemExit(bool(found))
