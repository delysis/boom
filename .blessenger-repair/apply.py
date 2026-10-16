#!/usr/bin/env python3
"""Apply the exact captured-model, ancestry and private-backup repair."""
import gzip, hashlib, os, pathlib, subprocess
BASE = 'bf155ca44ec1dd734e5fd9355717d857a7be2034'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-repair/**').strip(), 'Intervening source changes'
compressed = pathlib.Path('.blessenger-repair/source.patch.gz').read_bytes()
assert len(compressed) == 9201 and hashlib.sha256(compressed).hexdigest() == '6a562e8ab1e55d02dd8591b3c9f9672fb418ccf1006f517be0a54cb64c1d98bd', 'Transport mismatch'
patch = gzip.decompress(compressed)
assert len(patch) == 34023 and hashlib.sha256(patch).hexdigest() == 'a4c23705707aa6b51aa2431c0da4952757c9291279aefe30d111f8e4bc224945'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply', '--check', '--index', '--binary', '-'), ('apply', '--index', '--binary', '-')]:
    subprocess.run(['git', *args], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-repair')
print('Exact model-binding, ancestry and backup repair applied. No application qualification is inferred.')
