# Local MP3 stream fixture

The fixture binds to `127.0.0.1` on a free port, loops a deterministic MP3,
and throttles the response so the native player sees a continuing stream. It
prints its base URL after it starts.

Generate the ignored audio file and run the tests:

```bash
cd experiments/webview-player/fixtures
./generate-tone.sh
node --test serve.test.mjs
```

Start the fixture and copy the printed URL. The default `--port 0` asks the OS
for a free port.

```bash
cd experiments/webview-player/fixtures
node serve.mjs
```

If the fixture prints `http://127.0.0.1:43127`, launch the proof with:

```bash
cd experiments/webview-player
SUBWAVE_PROOF_STREAM_URL=http://127.0.0.1:43127/stream.mp3 ./zig-out/bin/webview-player
```

Use the same printed base URL to inspect or control the fixture:

```bash
curl http://127.0.0.1:43127/_fixture/stats
curl -X POST http://127.0.0.1:43127/_fixture/reset
curl -X POST http://127.0.0.1:43127/_fixture/drop
```

`stats` returns `activeConnections` and `totalConnections`. `reset` resets the
total counter without interrupting playback. `drop` closes every active stream
so the proof can demonstrate its buffering or error transition. Controls are
available only to loopback clients, accept at most 1024 request-body bytes, and
require the methods shown above.

For repeatable throughput experiments, override the defaults explicitly:

```bash
node serve.mjs --file ./tone.mp3 --port 0 --chunk-bytes 1600 --interval-ms 100
```

The default rate is 16,000 bytes per second, matching the generated 128 kbit/s
MP3 so a long-running proof does not build an artificial server-side backlog.

Press Ctrl-C to stop the fixture. Shutdown and client disconnects clear all
per-stream timers and sockets.
