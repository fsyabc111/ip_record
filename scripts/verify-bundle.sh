#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="${1:-$PWD/dist/IP Record.app}"
codesign --verify --strict --verbose=2 "$app"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" == local.fsy.iprecord ]]
[[ "$(plutil -extract LSUIElement raw -o - "$app/Contents/Info.plist")" == true ]]
[[ "$(lipo -archs "$app/Contents/MacOS/IPRecord")" == arm64 ]]
python3 - "$app" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
app = Path(sys.argv[1])
manifest = json.loads(Path('data/ip2region/manifest.json').read_text())
for entry in manifest['files']:
    if entry['path'].endswith('.xdb'):
        path = app / 'Contents/Resources/ip2region' / Path(entry['path']).name
        assert path.stat().st_size == entry['bytes']
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(65536), b''):
                digest.update(block)
        assert digest.hexdigest() == entry['sha256']
assert not list(app.rglob('*.py'))
assert (app / 'Contents/Resources/ip2region/LICENSE.md').is_file()
print('Bundle identity, arm64, LSUIElement, dual XDB and license verified; no Python runtime.')
PY
otool -L "$app/Contents/MacOS/IPRecord"
