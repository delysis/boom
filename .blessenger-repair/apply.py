#!/usr/bin/env python3
"""Apply the exact captured implementation; reject base or transport changes."""
import gzip, hashlib, os, pathlib, subprocess
BASE = '82cb6474be593d1c9b49583a6f0213f2d88d96b9'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-repair/**').strip(), 'Intervening source changes'
root = pathlib.Path('.blessenger-repair')
parts = sorted(root.glob('part-*'))
assert [p.name for p in parts] == [f'part-{i:02d}' for i in range(5)]
received = pathlib.Path('evidence/received-parts')
received.mkdir()
for p in parts:
    data = p.read_bytes()
    assert len(data) <= 6000
    (received / p.name).write_bytes(data)
compressed = b''.join(p.read_bytes() for p in parts)
assert len(compressed) == 28568 and hashlib.sha256(compressed).hexdigest() == 'ddebba2d29cfa083c3846cd898857d508bbfb6e46e6604838da7544f397f5e2d', 'Transport mismatch; original source retained'
patch = gzip.decompress(compressed)
assert len(patch) == 114453 and hashlib.sha256(patch).hexdigest() == 'f78c11682f22d882d321148a400a302f645a1499620b66a1ea7cb21faba2edea'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply', '--check', '--index', '--binary', '-'), ('apply', '--index', '--binary', '-')]:
    subprocess.run(['git', *args], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-repair')
print('Verified exact implementation admitted; compilation and regression checks follow.')
