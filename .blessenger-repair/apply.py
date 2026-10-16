#!/usr/bin/env python3
"""Import exact source on the owned review branch, with no workflow changes."""
import gzip,hashlib,os,pathlib,subprocess
BASE='986397d795b50401fe1d05a24a170e9275a17cdb'
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**').strip(), 'Intervening source change'
parts=sorted(pathlib.Path('.blessenger-repair').glob('part-*'))
assert [p.name for p in parts]==['part-00','part-01']
compressed=b''.join(p.read_bytes() for p in parts)
assert len(compressed)==10436 and hashlib.sha256(compressed).hexdigest()=='ff58865efaec5b6872c6393c2caaae24ad76b05cf073d40e8ef498c7528b1281'
patch=gzip.decompress(compressed)
assert len(patch)==37692 and hashlib.sha256(patch).hexdigest()=='7420b2bfa890531f3b407c6a97d9074bb360f5ee88f87be96dbf5c47aae3a106'
assert b'diff --git a/.github/' not in patch
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','--binary','-'),('apply','--index','--binary','-')]:
    subprocess.run(['git',*args],input=patch,check=True)
git('rm','-r','--','.blessenger-repair')
print('Exact Settings, private archive, and call-admission repair applied; tests follow.')
