#!/usr/bin/env python3
"""Install the same pinned Metal library in tests and packaged applications."""
import os, pathlib, subprocess
BASE='fcf9f5c6f0238521eaecd00c25807ed94d395e38'
def git(*args): return subprocess.check_output(['git', *args])
assert os.environ['GITHUB_REPOSITORY']=='delysis/boom'
assert os.environ['GITHUB_REF']=='refs/heads/blessenger/port-20261016'
assert git('rev-parse','HEAD').decode().strip()==os.environ['GITHUB_SHA']
git('merge-base','--is-ancestor',BASE,'HEAD')
assert not git('diff','--name-only',BASE,'HEAD','--','.',':!.blessenger-repair/**',':!.github/workflows/blessenger-native-candidate.yml',':!scripts/build-mlx-metallib.sh').strip()
p=pathlib.Path('scripts/build-macos.sh')
assert git('hash-object',str(p)).decode().strip()=='3b4fae1abb0dd77d373b600c415ad86d8902c332'
s=p.read_text()
a='(cd "$HERE/App" && swift test --manifest-cache none --disable-automatic-resolution --disable-experimental-prebuilts)'
b='''(cd "$HERE/App" && swift build --build-tests --manifest-cache none --disable-automatic-resolution --disable-experimental-prebuilts)
DEBUG_BIN="$(cd "$HERE/App" && swift build --show-bin-path --manifest-cache none --disable-automatic-resolution --disable-experimental-prebuilts)"
"$HERE/scripts/build-mlx-metallib.sh" "$DEBUG_BIN/mlx.metallib"
[[ -d "$DEBUG_BIN/BoomPackageTests.xctest/Contents/MacOS" ]]
cp "$DEBUG_BIN/mlx.metallib" "$DEBUG_BIN/BoomPackageTests.xctest/Contents/MacOS/mlx.metallib"
(cd "$HERE/App" && swift test --skip-build --manifest-cache none --disable-automatic-resolution --disable-experimental-prebuilts)'''
assert s.count(a)==1;s=s.replace(a,b)
a='cp "$BIN/Boom" "$APP/Contents/MacOS/$PRODUCT_NAME"'
b='''cp "$BIN/Boom" "$APP/Contents/MacOS/$PRODUCT_NAME"
# The same exact shaders used by native tests accompany the release binary.
cp "$DEBUG_BIN/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"'''
assert s.count(a)==1;s=s.replace(a,b);p.write_text(s)
assert git('hash-object',str(p)).decode().strip()=='8f14a6599e520f72b4df00c1b54a2fdb1762c4f5'
git('add',str(p));git('rm','-r','--','.blessenger-repair')
assert git('write-tree').decode().strip()=='f87b59bd89264aa51765d1cccdcf1f2a3e232b35'
