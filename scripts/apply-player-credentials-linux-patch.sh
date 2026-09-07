#!/usr/bin/env bash
# Apply the Linux libsecret ABI repair after the isolated transport patch.
# Usage: ./scripts/apply-player-credentials-linux-patch.sh --sdk-path /absolute/private/sdk [--check]
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$script_dir/.." "$@" <<'PY'
import argparse, hashlib, json, os, pathlib, subprocess, sys, tempfile

repo = pathlib.Path(sys.argv[1]).resolve()
parser = argparse.ArgumentParser(description="Apply or verify the private-SDK Linux libsecret ABI repair")
parser.add_argument("--sdk-path", type=pathlib.Path, required=True)
parser.add_argument("--check", action="store_true")
args = parser.parse_args(sys.argv[2:])
target = args.sdk_path.resolve(strict=True)
marker = target / ".subwave-player-private-sdk.json"
if not marker.is_file() or marker.is_symlink():
    raise SystemExit("Not a prepared private SDK copy; run apply-player-transport-patch.sh first")
metadata = json.loads(marker.read_text())
source = pathlib.Path(metadata["source"]).resolve(strict=True)
if metadata.get("version") != "0.10.1" or target == source or target.is_relative_to(source):
    raise SystemExit("Refusing SDK with an unexpected version/source relationship")

# This second patch is intentionally based on the fully applied transport SDK.
# Validate every other transport output directly because this patch changes one
# of the hashes that the first installer's standalone --check pins.
transport = json.loads((repo / "patches/native-sdk-player-transport.json").read_text())
for entry in transport["files"]:
    path = target.joinpath(*pathlib.PurePosixPath(entry["path"]).parts)
    if entry["path"] == "src/platform/linux/gtk_host.c":
        continue
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["after"]:
        raise SystemExit(f"Transport-prepared SDK hash mismatch: {entry['path']}")
relative = pathlib.Path("src/platform/linux/gtk_host.c")
destination = target / relative
if destination.is_symlink() or not destination.resolve().is_relative_to(target):
    raise SystemExit("Linux credential patch path escapes the private SDK")
before = "f2313c98fe11baced0f645051acffdf09ed6c0c255bb9bf1d7833844c42eda79"
after = "75a89f26718430121b0920012d318b01298c884f85ccc2fe32ebe88cf12bcec7"
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
current = digest(destination)
if current == after:
    print("Linux credential ABI patch already applied; file hash verified")
    sys.exit(0)
if current != before:
    raise SystemExit("gtk_host.c differs from the transport-prepared baseline; no changes made")
if args.check:
    raise SystemExit("Private SDK has the transport patch but lacks the Linux credential ABI patch")

# Compare our mirror with the system's actual public SecretSchema layout. This
# is compile-only and performs no secret-service or D-Bus operation.
probe = r'''
#include <stddef.h>
#include <libsecret/secret.h>
typedef struct mirror_attribute { const char *name; int type; } mirror_attribute_t;
typedef struct mirror_schema {
    const char *name; int flags; mirror_attribute_t attributes[32]; int reserved;
    void *reserved1; void *reserved2; void *reserved3; void *reserved4;
    void *reserved5; void *reserved6; void *reserved7;
} mirror_schema_t;
_Static_assert(sizeof(mirror_attribute_t) == sizeof(SecretSchemaAttribute), "attribute ABI mismatch");
_Static_assert(sizeof(mirror_schema_t) == sizeof(SecretSchema), "schema ABI mismatch");
_Static_assert(offsetof(mirror_schema_t, reserved) == offsetof(SecretSchema, reserved), "reserved offset mismatch");
_Static_assert(offsetof(mirror_schema_t, reserved7) == offsetof(SecretSchema, reserved7), "tail offset mismatch");
'''
try:
    flags = subprocess.check_output(["pkg-config", "--cflags", "libsecret-1"], text=True).split()
except (FileNotFoundError, subprocess.CalledProcessError) as error:
    raise SystemExit("libsecret-1 development headers are required for the ABI assertion") from error
with tempfile.TemporaryDirectory(prefix="subwave-libsecret-abi-") as directory:
    source_path = pathlib.Path(directory) / "check.c"
    object_path = pathlib.Path(directory) / "check.o"
    source_path.write_text(probe)
    subprocess.run([os.environ.get("CC", "cc"), *flags, "-std=c11", "-Werror",
                    "-c", str(source_path), "-o", str(object_path)], check=True)

patch = repo / "patches/native-sdk-credentials-linux.patch"
command = ["patch", "--batch", "--forward", "-p1", "-i", str(patch)]
subprocess.run(command + ["--dry-run"], cwd=target, check=True, capture_output=True)
original = destination.read_bytes()
try:
    subprocess.run(command, cwd=target, check=True, capture_output=True)
    if digest(destination) != after:
        raise RuntimeError("post-apply gtk_host.c hash differs from the pinned result")
except BaseException:
    destination.write_bytes(original)
    raise
print("Linux credential ABI patch applied and verified in private SDK copy")
PY
