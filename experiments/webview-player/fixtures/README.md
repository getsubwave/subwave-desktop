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

## Two-origin station fixture

`station.mjs` provides the station API contract plus a paced MP3 stream. It
starts two isolated literal-loopback origins and prints both URLs as one JSON
line. The second origin is the destination for redirect-policy tests.

```bash
cd experiments/webview-player/fixtures
./generate-tone.sh
node --test station.test.mjs serve.test.mjs
node station.mjs --auth-mode public
```

The public endpoints are exactly `/api/health`, `/api/state`,
`/api/now-playing`, `/api/session`, `/api/themes`, `/api/schedule`,
`/api/station-auth`, and `/stream.mp3`. Unknown paths return 404.

Use synthetic credentials for private modes. Arguments are convenient for
local disposable processes:

```bash
node station.mjs --auth-mode basic \
  --basic-username 'fixture-user' --basic-password 'fixture-basic-secret'

node station.mjs --auth-mode listener \
  --listener-password 'fixture-listener-secret'

node station.mjs --auth-mode combined \
  --basic-username 'fixture-user' --basic-password 'fixture-basic-secret' \
  --listener-password 'fixture-listener-secret'
```

Environment variables avoid credentials appearing in the process arguments:

```bash
FIXTURE_BASIC_USERNAME='fixture-user' \
FIXTURE_BASIC_PASSWORD='fixture-basic-secret' \
FIXTURE_LISTENER_PASSWORD='fixture-listener-secret' \
node station.mjs --auth-mode combined
```

Neither startup output nor counters contain credential values. Stats report
only request totals, successful requests, and whether Authorization or listener
authentication was present. Given a printed primary URL in `$PRIMARY` and
redirect URL in `$REDIRECT`, exercise the independent contracts with:

```bash
curl "$PRIMARY/api/health"
curl -u 'fixture-user:fixture-basic-secret' "$PRIMARY/api/now-playing"
curl -u 'fixture-user:fixture-basic-secret' \
  -H 'content-type: application/json' \
  --data '{"password":"fixture-listener-secret"}' \
  "$PRIMARY/api/station-auth"
curl -u 'fixture-user:fixture-basic-secret' \
  "$PRIMARY/stream.mp3?auth=fixture-listener-secret" --output /dev/null
```

Controls bind to loopback, accept JSON bodies of at most 1024 bytes, and allow
only public fixture paths. Configure a one-shot failure and an 80 ms delay,
then direct later requests to the second origin:

```bash
curl -H 'content-type: application/json' \
  --data '{"path":"/api/state","failures":1,"delayMs":80}' \
  "$PRIMARY/_fixture/config"
curl -H 'content-type: application/json' \
  --data '{"path":"/api/health","redirect":true}' \
  "$PRIMARY/_fixture/config"
curl -i "$PRIMARY/api/health"
curl "$PRIMARY/_fixture/stats"
curl "$REDIRECT/_fixture/stats"
```

Drop active streams or clear counters without changing configuration:

```bash
curl -X POST "$PRIMARY/_fixture/drop"
curl -X POST "$PRIMARY/_fixture/reset"
```

Stream concurrency is capped at 16 per origin. Delay is capped at two seconds,
configured failure counts at 100, and shutdown closes sockets and pacing timers.
