#!/usr/bin/env bash
# Apply only to an explicitly prepared private SDK copy; never the installed CLI.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$script_dir/.." "$@" <<'PY'
import argparse, hashlib, json, pathlib, shutil, subprocess, sys

repo = pathlib.Path(sys.argv[1]).resolve()
p = argparse.ArgumentParser(description='Prepare or verify/apply the isolated player transport SDK patch')
p.add_argument('--sdk-path', type=pathlib.Path, required=True)
p.add_argument('--prepare-from', type=pathlib.Path)
p.add_argument('--check', action='store_true')
a = p.parse_args(sys.argv[2:])
target = a.sdk_path.absolute()
marker_name = '.subwave-player-private-sdk.json'
manifest_path = repo / 'patches/native-sdk-player-transport.json'
patch_path = repo / 'patches/native-sdk-player-transport.patch'
manifest = json.loads(manifest_path.read_text())
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None

def validate_package(path):
    package = json.loads((path / 'package.json').read_text())
    if package.get('name') != '@native-sdk/cli' or package.get('version') != manifest['version']:
        raise SystemExit('SDK package/version differs from the transport patch baseline')

if a.prepare_from:
    if a.check:
        raise SystemExit('--check cannot create a private SDK copy')
    source = a.prepare_from.resolve(strict=True)
    validate_package(source)
    if target.exists() or target.is_symlink():
        raise SystemExit('Preparation target must not exist')
    if target.resolve().is_relative_to(source):
        raise SystemExit('Preparation target must be outside the source SDK')
    shutil.copytree(source, target, symlinks=True)
    (target / marker_name).write_text(json.dumps({'source': str(source), 'version': manifest['version']}) + '\n')

target = target.resolve(strict=True)
marker = target / marker_name
if not marker.is_file() or marker.is_symlink():
    raise SystemExit('Not a prepared private SDK copy; use --prepare-from with a new target')
meta = json.loads(marker.read_text())
source = pathlib.Path(meta['source']).resolve()
if target == source or target.is_relative_to(source):
    raise SystemExit('Refusing to patch the source/installed SDK')
validate_package(target)
files = []
for entry in manifest['files']:
    relative = pathlib.PurePosixPath(entry['path'])
    if relative.is_absolute() or '..' in relative.parts:
        raise SystemExit('Invalid path in patch manifest')
    dest = target.joinpath(*relative.parts)
    if dest.is_symlink() or not dest.resolve().is_relative_to(target):
        raise SystemExit('Patch path escapes private SDK')
    files.append((entry, dest, digest(dest)))
if all(current == entry['after'] for entry, _, current in files):
    print('Player transport patch already applied; file hashes verified')
    sys.exit(0)
if not all(current == entry['before'] for entry, _, current in files):
    raise SystemExit('SDK files differ from both clean and patched baselines; no changes made')
if a.check:
    raise SystemExit('Private SDK is clean but player transport patch is not applied')
cmd = ['patch', '--batch', '--forward', '-p1', '-i', str(patch_path)]
subprocess.run(cmd + ['--dry-run'], cwd=target, check=True, capture_output=True)
original = {str(path): path.read_bytes() if path.exists() else None for _, path, _ in files}
try:
    subprocess.run(cmd, cwd=target, check=True, capture_output=True)
    if not all(digest(path) == entry['after'] for entry, path, _ in files):
        raise RuntimeError('Post-apply SDK hashes differ from manifest')
except BaseException:
    for name, data in original.items():
        path = pathlib.Path(name)
        if data is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(data)
    raise
print('Player transport patch applied and verified in private SDK copy')
PY
