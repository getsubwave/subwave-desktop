# Station foundation checkpoint

The isolated experiment now owns canonical station identity, protocol-2 command
parsing and sanitized serialization, independent bounded API requests and a
candidate health gate. This checkpoint does not attach them to the player UI;
credentials, session playback and persistence are subsequent integration work.

The health decoder follows the actual controller response
`{"status":"on-air"}`. An accepted candidate becomes active only after its exact
operation/generation/request/endpoint tag returns healthy. Failed or canceled
candidates preserve the active identity. The client denies redirects and bounds
request capacity, headers, bodies and response lifetimes. JSON command parser
allocations are wiped when released, including malformed input paths.

## Verification

From `experiments/webview-player`, with the private SDK prepared as documented
in `docs/sdk-player-transport.md`:

```sh
zig build test-foundation -Dtrace=off -Dnative-sdk-path=../../.superpowers/player-transport-sdk --summary all
node --test fixtures/station.test.mjs
zig build -Dtrace=off -Drequest-probe=true -Dnative-sdk-path=../../.superpowers/player-transport-sdk --prefix /tmp/subwave-request-foundation
```

Checkpoint results: **35 native foundation tests and 14 fixture tests passed**.
The Linux request probe compiled and ran against a temporary literal-loopback
fixture with its health response delayed 500 ms. All three responses arrived
through `effects_wake`: health activated generation 1, then now-playing and state
completed independently. The executable exited successfully after all three.
No audio, shipping configuration or real credentials were used by this probe.

To reproduce the runtime portion, start `node fixtures/station.mjs` and use its
printed primary origin as `SUBWAVE_REQUEST_FIXTURE`. Set temporary
`XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `NATIVE_SDK_LOG_DIR`; run the above probe
binary in an existing desktop session. Stop the fixture after verification.

## Remaining boundaries

The full foundation plan remains open. The request owner is currently bound by
a dedicated runtime probe; the main/mini interface still uses the earlier proof
contract. Private candidate validation and vault persistence must precede its
activation in the final host. The SDK HTTP effects currently allow 1024 aggregate
header bytes, while vault entries allow 2560 bytes: transport size is explicitly
rejected before request admission, and private-station UX must honor that limit
or use a separately verified SDK expansion. Real macOS/Windows execution is
still required. See the foundation plan for session, vault, import and UI work.
