#!/usr/bin/env python3
"""Fake compiler for launcher fault tests; never reports native acceptance."""
from pathlib import Path
import shutil
import os
import sys
import time

root = Path.cwd()
source = root / 'examples/storybook/stories.zig'
# The test controls these files outside the launcher's watched inputs.
(root / 'build-started').write_text(str(os.getpid()))
while (root / 'hold-build').exists():
    time.sleep(.01)
if b'@compileError' in source.read_bytes():
    print('examples/storybook/stories.zig:42:5: error: LP1 deliberate compile failure')
    sys.exit(1)
prefix = Path(sys.argv[sys.argv.index('--prefix') + 1])
binary = prefix / 'bin' / 'storybook'
binary.parent.mkdir(parents=True)
shutil.copyfile(root / 'peer.py', binary)
binary.chmod(0o755)
