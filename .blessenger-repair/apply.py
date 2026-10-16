#!/usr/bin/env python3
"""Admit only the captured incremental audio implementation and its regressions."""
import gzip, hashlib, os, pathlib, subprocess
BASE = '43d772937449b745576f5174593c9dbc13eebaca'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-repair/**').strip(), 'Intervening source changes'
parts = sorted(pathlib.Path('.blessenger-repair').glob('part-*'))
assert [p.name for p in parts] == [f'part-{i:02}' for i in range(8)]
compressed = b''.join(p.read_bytes() for p in parts)
assert len(compressed) == 15326 and hashlib.sha256(compressed).hexdigest() == '9fe12fa82439105d052f3c97b5d2e7f68e2e8780aa97bdfbfe06778a804276b3', 'Transport mismatch'
patch = gzip.decompress(compressed)
assert len(patch) == 60257 and hashlib.sha256(patch).hexdigest() == '89cedb49b6114ba81fee53437dba595036d0a6b453acc31a8e0f23987238e102'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply', '--check', '--index', '--binary', '-'), ('apply', '--index', '--binary', '-')]:
    subprocess.run(['git', *args], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-repair')
assert git('write-tree').decode().strip() == 'a1a5f0017388cd74c579b79b9f35ddc62679acab', 'Complete source tree mismatch'
print('Exact immutable audio-prefix integration applied. Native compilation and CPU parity tests follow.')
