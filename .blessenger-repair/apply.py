#!/usr/bin/env python3
"""Apply rustfmt's exact reported layout; preserve all behavioral checks."""
import os,pathlib,subprocess
BASE='6a671c85ee4fa1df29c0a315be14bfe5e2a32dda'
def git(*args): return subprocess.check_output(['git',*args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**').strip()
p=pathlib.Path('crates/bloom-core/src/writing.rs')
assert git('hash-object',str(p)).decode().strip()=='a52bd2e2215d3cc7a050ba43b7b83e66c8b4e39f'
a=b'digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())\n                        })'
b=b'digest.len() == 64\n                                && digest.bytes().all(|byte| byte.is_ascii_hexdigit())\n                        })'
data=p.read_bytes();assert data.count(a)==1;p.write_bytes(data.replace(a,b))
assert git('hash-object',str(p)).decode().strip()=='e31f7b8fbce202f20650f59cdf9bfa293b2db66f'
git('add',str(p));git('rm','-r','--','.blessenger-repair')
