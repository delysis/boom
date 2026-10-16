#!/usr/bin/env python3
"""One-time, hash-verified source import on the owned review branch."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

BASE = 'b56eca83b6c7292e50020643a5fc1aee4cf44323'
TREE = 'f8f82f58b181b519412720d68425e6adcb5514e4'
PATCH_SHA = 'c7111299b9ca67889ba90f22118270afa0045e6c902c3ef6016a840819c5a3b7'
GZIP_SHA = '3c7c2d5ffeb2e4823da89a8db0e4ee7394e7c9b91800127fb92329bb800e5030'
WORKFLOW = '.github/workflows/blessenger-import.yml'
def git(*args, env=None):
    return subprocess.check_output(['git', *args], env=env)

assert os.environ.get('GITHUB_REPOSITORY') == 'delysis/boom'
assert os.environ.get('GITHUB_REF') == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-import/**', ':!' + WORKFLOW).strip(), 'Unexpected intervening source changes'
root = Path('.blessenger-import')
parts = sorted(root.glob('part-*'))
assert [p.name for p in parts] == [f'part-{n:02d}' for n in range(10)]
received = Path('evidence/received-parts')
received.mkdir(parents=True, exist_ok=False)
manifest = []
for p in parts:
    data = p.read_bytes()
    assert len(data) <= 8192, 'Unbounded source part'
    (received / p.name).write_bytes(data)
    manifest.append({'part': p.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
(received / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
compressed = b''.join(p.read_bytes() for p in parts)
assert len(compressed) == 56399 and hashlib.sha256(compressed).hexdigest() == GZIP_SHA, 'Transport mismatch; preserved received bytes, source not changed'
patch = gzip.decompress(compressed)
assert len(patch) == 213180 and hashlib.sha256(patch).hexdigest() == PATCH_SHA
Path('evidence/authored.patch').write_bytes(patch)
subprocess.run(['git', 'apply', '--check', '--index', '--binary', '-'], input=patch, check=True)
subprocess.run(['git', 'apply', '--index', '--binary', '-'], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-import')
with tempfile.TemporaryDirectory() as temporary:
    index = Path(temporary) / 'index'
    shutil.copyfile(git('rev-parse', '--git-path', 'index').decode().strip(), index)
    env = dict(os.environ, GIT_INDEX_FILE=str(index))
    git('update-index', '--force-remove', WORKFLOW, env=env)
    actual = git('write-tree', env=env).decode().strip()
    assert actual == TREE, f'Complete source tree mismatch: {actual}'
Path('evidence/authored-tree.txt').write_text(TREE + '\n')
print('Verified and applied the complete authored tree. Formatting and compilation follow; no acceptance is inferred.')
