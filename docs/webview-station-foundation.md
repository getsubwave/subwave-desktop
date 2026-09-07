# Station foundation checkpoint

The isolated WebView experiment now implements the protocol-2 station core through Tasks 4–6. React sends typed intents and renders sanitized snapshots. One Zig model owns candidate selection, HTTP, native audio, timers, credentials and preferences; views do not own sessions or receive credentials, upstream URLs or raw station responses.

The candidate transaction reads both vault records before probing, keeps the active session unchanged until health and listener validation succeed, and serializes credential changes. Failed or cancelled changes compensate completed vault writes before releasing the station-mutation slot. Every HTTP, vault, timer and audio completion carries its operation, generation, request, endpoint or load identity and stale completions are ignored.

Private audio uses the app-owned loopback relay described in `docs/sdk-player-transport.md`. The native player receives a credential-free loopback URL; the relay owns upstream Basic authentication, listener query encoding and redirect denial. The private SDK patch adds per-load native audio identity. It does not use undocumented AVFoundation header options. Linux credential callbacks use the subsequent `patches/native-sdk-credentials-linux.patch`.

Preferences are bounded version-2 JSON written through an owner-only atomic replacement, file sync and parent-directory sync where supported. Saves are serialized and retain the latest dirty revision. Legacy import reads at most 8192 bytes, preserves a byte-exact create-once backup, writes only absent vault records, verifies new records, then commits sanitized preferences and an import digest. The original legacy file is retained. Station removal first persists a `pendingRemoval` marker, performs idempotent vault deletion, then commits the station removal; startup resumes a durable pending removal.

After remote validation and credential commitment, a native device failure is reported as playback error on the confirmed selected station. The station and its validated credentials remain available for Play to retry; this is distinct from a failed candidate validation or vault write, which preserves the previous session. Candidate preferences and removal markers are allocated before their transaction begins, so preparation failure cannot follow a credential or disk commit.

Production bridge commands are restricted to `zero://app`. The exact Vite origin is compiled only with `-Dfrontend-dev=true`; `zero://inline` is compiled only with `-Dautomation=true`. Both windows use bundled asset sources and the same command policy. Snapshots are capped below the SDK bridge limit and omit secrets.

## Build and focused checks

Prepare the private SDK copy as documented in `docs/sdk-player-transport.md`:

```sh
./scripts/apply-player-transport-patch.sh --sdk-path /abs/private-sdk --prepare-from /abs/sdk-base
./scripts/apply-player-transport-patch.sh --sdk-path /abs/private-sdk --check
./scripts/apply-player-credentials-linux-patch.sh --sdk-path /abs/private-sdk
./scripts/apply-player-credentials-linux-patch.sh --sdk-path /abs/private-sdk --check
```

Run these four commands from the repository root and in this order. The credential installer requires the prepared transport marker, validates the other transport hashes, checks the installed libsecret ABI with compile-time size/offset assertions, dry-runs, and rolls back a failed apply. The credential `--check` validates the combined final copy.

Then run from `experiments/webview-player`:

```sh
npm --prefix frontend ci
npm --prefix frontend run build
zig build test-foundation -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk --summary all
node --test fixtures/station.test.mjs
zig build -Dfoundation=true -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-foundation-build
```

For synthetic GUI automation, create a fresh directory whose canonical path is beneath `/tmp/subwave-foundation-*`, then compile the automation-only origin and vault adapter:

```sh
preview_state="$(mktemp -d /tmp/subwave-foundation-preview.XXXXXX)"
mkdir -p "$preview_state/vault" "$preview_state/config" "$preview_state/cache" "$preview_state/data"
zig build -Dfoundation=true -Dautomation=true -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-foundation-automation
env -u SUBWAVE_STATION_URL -u NATIVE_SDK_FRONTEND_URL \
  XDG_CONFIG_HOME="$preview_state/config" XDG_CACHE_HOME="$preview_state/cache" \
  XDG_DATA_HOME="$preview_state/data" SUBWAVE_TEST_VAULT_DIR="$preview_state/vault" \
  /tmp/subwave-foundation-automation/bin/webview-player-foundation
```

`automation_vault.zig` is a persistent file-backed store for generated test credentials only. Its tests prove SDK callback outcomes, bounds, restart, locking and path containment. They do not test Keychain, Credential Manager or Secret Service. The Linux integrated gate below uses this synthetic vault; real Secret Service behavior remains a release gate.

## Runtime reproduction

The dedicated request and public-session probes remain useful focused checks:

```sh
zig build -Dtrace=off -Drequest-probe=true \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-request-foundation
zig build -Dtrace=off -Dsession-probe=true \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-session-foundation
cd ../..
python3 scripts/check-player-session-linux.py \
  --binary /tmp/subwave-session-foundation/bin/session-probe
```

The final integrated Linux run passed with the automation build whose SHA-256 was `bd5905b92b63205dfccaf457003a7eb09d0ac909555bd85c2f57e88b577c3a50`:

```bash
XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:0 \
  python3 scripts/check-player-foundation-linux.py \
  --binary experiments/webview-player/zig-out/bin/webview-player-foundation \
  --resources experiments/webview-player/frontend/dist --timeout 25
```

The checker proved React readiness before automation reads, protocol 2, public and private station switching, Basic and listener authentication on APIs and native audio, native FFT, combined-auth PCM at -34.5 dBFS, drop/reconnect, bounded per-view spectrum delivery, mini/open/hide/reload, import consent and restart, and active-station forget without replacing its live stream. It also scanned temporary artifacts for credential sentinels and verified shutdown cleanup. The sanitized result is [linux-foundation.json](../experiments/webview-player/evidence/linux-foundation.json).

macOS and Windows runtime validation remain open gates. The Windows foundation compiles and links, which is build evidence only. Real Linux Secret Service behavior also remains open because the integrated credential run intentionally uses the hermetic synthetic vault.
