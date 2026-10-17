#!/usr/bin/env python3
"""Apply only the hash-verified transcript Undo and bounded-media closure."""
import gzip, hashlib, os, pathlib, subprocess
BASE = '652a34943a729e1a860a520342b4df538e0f21b7'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-repair/**').strip(), 'Intervening source changes'
root = pathlib.Path('.blessenger-repair')
parts = sorted(root.glob('part-*'))
assert [p.name for p in parts] == ['part-0', 'part-1', 'part-2']
compressed = b''.join(p.read_bytes() for p in parts)
assert len(compressed) == 6920 and hashlib.sha256(compressed).hexdigest() == 'e3f5ed9cea7e103b6ae30aa8078fb64c9c0344bc94d156b73957286eab17f87d', 'Transport mismatch'
patch = gzip.decompress(compressed)
assert len(patch) == 22616 and hashlib.sha256(patch).hexdigest() == '0d121e2f36fb66edc8f3f0403675051063f2cfcc75f4317122aaf15a6e68eaf9'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply', '--check', '--index', '--binary', '-'), ('apply', '--index', '--binary', '-')]:
    subprocess.run(['git', *args], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-repair')
print('Exact transcript Undo and decoded-context closure applied. Native compilation and regressions follow.')
