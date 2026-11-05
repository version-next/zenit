#!/usr/bin/env python3
"""Require a nonempty release symbol table and absence of the LP4 runtime."""
import argparse
import json
from pathlib import Path
import re
import subprocess
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path); parser.add_argument('--output', type=Path)
args = parser.parse_args()
run = subprocess.run(['nm', str(args.binary)], capture_output=True, text=True, check=True)
symbols = [line for line in run.stdout.splitlines() if line.strip()]
if len(symbols) < 100: raise SystemExit('release erasure needs an unstripped, nonempty symbol table')
pattern = re.compile(r'emitRegion|emitSlot|slot_region_pending|template_region_pending|template_region_identity|retainedFactorySafe|retainedValueSafe|retainedPropertySafe|TemplateChildMove|TemplateChild\.|AttachmentReplay|stageTemplateChild|recordTemplateChild|lookupRegion|retainRelocatedTemplateChild|PreviewFunctionIdentity|PreviewScopeWatch|PreviewRootSnapshot|discardPreviewRootWhileGuarded|preview_mount|mount_effects|templateFallbackInto|fail_commit_at|deferAction|previewCheckBuilder|previewCheckSetup|commit_reentered|requestRemount|template_reload|reload_templates|query_template|activate_template|close_preview_window|prepareView|PreparedView|compilePreview|validatePreviewContext|transactionOwnerSafe|TemplateInjectedFailure|preview_template|__yix_preview_|__YixStyleCatalog|styleCatalog|catalogStyles|catalogRoots|catalogStyleCompatible|PreviewFormat', re.I)
found = [line for line in symbols if pattern.search(line)]
root = Path(__file__).resolve().parents[1]
binary_bytes = args.binary.read_bytes()
source_matches = {name: (root/'examples/template_probe'/name).read_bytes() in binary_bytes for name in ('view.yix', 'remount.yix', 'regions.yix')}
source_bytes_present = any(source_matches.values())
report = dict(binary=str(args.binary), symbols=len(symbols), lp4_symbols=len(found), matches=found, source_bytes_present=source_bytes_present, source_matches=source_matches)
if args.output: args.output.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report)); raise SystemExit(bool(found) or source_bytes_present)
