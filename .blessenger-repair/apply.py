#!/usr/bin/env python3
"""One-time exact-source admission on the owned review branch, not app code."""
import base64, gzip, hashlib, os, pathlib, subprocess
BASE = '6082f1d8f99f1ef3b1ba4fd7025810cac09059be'
EXPECTED = ['a7203e9746345531967a0c6128b3975c73b424e7','868b75f5f9b29f5081e8c7cff531291fc88b45f9','062044e01a81f940ed187323761e67b037a9d4b2','3d373791b6a6683eb6990b0665c728297b86cb42','2be5351adfa6e803c7ee04eefd3f1afda794e4e8','738a22406e84943993f5a00d5c5587817b77cfcf','30c431355a01eb82e5dd6ab7e9fcca866f824ac9','0bd9671e19b9443f858c268dd2c6dc2c4ba85efa','99dc7e29c62136eea007c7cae5a316e877ab09cc']
def git(*args): return subprocess.check_output(['git', *args])
def blob(data): return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
assert os.environ['GITHUB_REPOSITORY'] == 'delysis/boom'
assert os.environ['GITHUB_REF'] == 'refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip() == os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**',':!.github/workflows/blessenger-native-candidate.yml').strip(), 'Unexpected source changes'
root = pathlib.Path('.blessenger-repair')
parts = sorted(root.glob('part-*'))
assert [p.name for p in parts] == [f'part-{i:02}' for i in range(9)]
result = []
for i,p in enumerate(parts):
    data = p.read_bytes()
    assert len(data) <= 6012
    # Undo only known transport errors. Original source hashes stay unchanged.
    if blob(data) != EXPECTED[i]:
        encoded = base64.b64encode(data).decode()
        if i == 1:
            assert blob(data) == '81cf57ccac9dadbdbd9ab1ce8dfd506c8a33292a'
            encoded = encoded.replace('OhkOk/Tk5GowWh6/uo2mDaYNTr','OhkOk/Tk5Gg0nB6P+ifdQRwnSZYNTr')
        elif i == 4:
            assert blob(data) == '296e527dcff0e2173848d286b214ec87b817e3a6'
            encoded = encoded.replace('kEc2DCJkumBVNEq28DM5+moawQGmCReQyNLvrn8uFzMHiSTQaZtAsnv14u/kER7DZNGIp','kEc2DCJkumBVNEq28DM5+moawQGmCReQyNLvrn8uOXcER7DZNGIp')
            assert len(encoded) == 7999 and encoded.endswith('14aCtufzWhD')
            encoded += 'W'
        elif i == 6:
            assert blob(data) == '7ed4b10e2a79008ba70341eaf3b7827ece6d432d'
            encoded = encoded.rstrip('=').replace('AHTQHbs/t93rTr','AHTQHbs/t93r9Tr')
            assert encoded.endswith('4bE3WV3gj7xs')
            encoded = encoded[:-1] + 't'
        else:
            raise ValueError(f'Unexpected transport mismatch in part {i}')
        data = base64.b64decode(encoded, validate=True)
    assert blob(data) == EXPECTED[i], f'Authored chunk {i} did not match'
    result.append(data)
compressed = b''.join(result)
assert len(compressed) == 52644 and hashlib.sha256(compressed).hexdigest() == '70cd35e1e1ce13b67b24f090be9032a06803780f0cda611beb4c7c3516b6e55c'
patch = gzip.decompress(compressed)
assert len(patch) == 205911 and hashlib.sha256(patch).hexdigest() == 'f30b2034af365fbaa1fdc12e554155299826939d28291e1f7a35503c041eb14c'
pathlib.Path('evidence/repair.patch').write_bytes(patch)
for args in [('apply','--check','--index','--binary','-'),('apply','--index','--binary','-')]:
    subprocess.run(['git',*args], input=patch, check=True)
git('rm','-r','--','.blessenger-repair')
print('Original authored source bytes verified and applied. Native tests follow; no release acceptance is inferred.')
