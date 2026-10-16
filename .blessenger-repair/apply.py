#!/usr/bin/env python3
"""Apply the exact reviewed repair, never an approximate transport."""
import gzip,hashlib,os,pathlib,subprocess
BASE='f597ff64497f09ac16387cb9d9e24b672dae7073'
ROOT=pathlib.Path('.blessenger-repair')
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**',':!.github/workflows/blessenger-native-candidate.yml').strip(), 'Unexpected source change'
parts=sorted(ROOT.glob('part-*'))
assert [p.name for p in parts]==[f'part-{i:02}' for i in range(8)]
compressed=b''.join(p.read_bytes() for p in parts)
assert len(compressed)==44463 and hashlib.sha256(compressed).hexdigest()=='e803932f907fbe93bb3d287bb3350d22b6e839020af45d83b72a7964e77e8f38'
patch=gzip.decompress(compressed)
assert len(patch)==165991 and hashlib.sha256(patch).hexdigest()=='72be4a98484ae2f4c19f5ee19d7b47b2286187ee43bedc683c4fde7ceaad98e4'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','--binary','-'),('apply','--index','--binary','-')]:
    subprocess.run(['git',*args],input=patch,check=True)
git('rm','-r','--','.blessenger-repair')
print('Verified repair applied without changing its bytes.')
