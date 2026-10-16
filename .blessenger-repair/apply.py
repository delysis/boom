"""Apply an exact source-bound native input repair."""
import hashlib, os, pathlib, subprocess
BASE='5b02e7e5ef7d4b9570bb4fb70937d62d2fcb1cf2'
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**').strip()
patch=pathlib.Path('.blessenger-repair/source.patch').read_bytes()
assert hashlib.sha256(patch).hexdigest()=='1e66f019a96f26f02029165abb8c39b4df76103232c939df17a5069dc45804ff'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','-'),('apply','--index','-')]:
 subprocess.run(['git',*args],input=patch,check=True)
git('rm','-r','--','.blessenger-repair')
