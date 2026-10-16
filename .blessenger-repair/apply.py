#!/usr/bin/env python3
"""Apply only the captured speech-lifetime and audio-identity repair."""
import gzip, hashlib, os, pathlib, subprocess
BASE = '745025d0e7a8cd96eba03ea0b5ed25c58ae16910'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse', 'HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base', '--is-ancestor', BASE, 'HEAD')
assert not git('diff', '--name-only', BASE, 'HEAD', '--', '.', ':!.blessenger-repair/**').strip(), 'Intervening source changes'
compressed = pathlib.Path('.blessenger-repair/source.patch.gz').read_bytes()
assert len(compressed) == 8646 and hashlib.sha256(compressed).hexdigest() == '6d0fdf8b21e4f48ddbd4424c29304c95163d27d0ef4ddce16cae1d98bd8332bc', 'Transport mismatch'
patch = gzip.decompress(compressed)
assert len(patch) == 29500 and hashlib.sha256(patch).hexdigest() == 'a56776519ad7e5ffdb2b0caac410b2b7cd164cbb050873109575995b49da5f58'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply', '--check', '--index', '--binary', '-'), ('apply', '--index', '--binary', '-')]:
    subprocess.run(['git', *args], input=patch, check=True)
git('rm', '-r', '--', '.blessenger-repair')
print('Exact speech and admitted-audio repair applied; real CPU audio-prefix parity and native lifecycle tests follow.')
