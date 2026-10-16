"""Apply the exact lifecycle and media-input repair to its captured source."""
import gzip, hashlib, os, pathlib, subprocess
BASE='a42d12d9698378f2d7e0d020cf1efe108f49743c'
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**').strip(), 'Intervening source changes'
compressed=pathlib.Path('.blessenger-repair/source.patch.gz').read_bytes()
assert len(compressed)==8989 and hashlib.sha256(compressed).hexdigest()=='0da01445b49bc97db0e4789f77d3b8935df7da7eebb8f059c1408ecb833ed558'
patch=gzip.decompress(compressed)
assert len(patch)==35131 and hashlib.sha256(patch).hexdigest()=='0d1ea6f4b52127199f11c992e05c1397e647a440f4972ace3f050af7633b360a'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','--binary','-'),('apply','--index','--binary','-')]:
 subprocess.run(['git',*args],input=patch,check=True)
git('rm','-r','--','.blessenger-repair')
print('Exact lifecycle and media repair applied. Native tests follow on these bytes.')
