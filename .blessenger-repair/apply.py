#!/usr/bin/env python3
"""Admit the exact compile repair; refuse a changed base or transport."""
import hashlib, os, pathlib, subprocess
BASE='8d90fd0d7a1b1b2e6fd374b666a7cd666b14fec5'
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**').strip(), 'Intervening source changes'
root=pathlib.Path('.blessenger-repair')
patch=(root/'source.patch').read_bytes()+(root/'tests.patch').read_bytes()
assert hashlib.sha256(patch).hexdigest()=='b208d427bab4b48b66372f05814eba8a762563b7cbad1b08bedb6467308f8258'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','--binary','-'),('apply','--index','--binary','-')]:
    subprocess.run(['git',*args],input=patch,check=True)
git('rm','-r','--','.blessenger-repair')
print('Exact native compilation repair applied. Tests follow on these bytes.')
