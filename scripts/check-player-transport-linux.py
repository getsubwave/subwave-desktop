#!/usr/bin/env python3
"""Real Linux decoder proof using synthetic credentials and a private audio sink."""
import argparse
import base64
import contextlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import urllib.request
import wave


def request(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.load(response)


def terminate(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    fixture_dir = root / "experiments/webview-player/fixtures"
    env = os.environ.copy()
    if not env.get("XDG_RUNTIME_DIR"):
        raise SystemExit("Run in a Linux desktop session with XDG_RUNTIME_DIR set")
    sink = f"subwave_transport_check_{os.getpid()}"
    module = subprocess.check_output([
        "pactl", "load-module", "module-null-sink", f"sink_name={sink}"
    ], env=env, text=True).strip()
    if not module.isdecimal():
        raise RuntimeError("Unexpected Pulse module identifier")
    fixture = probe = capture = None
    try:
        with tempfile.TemporaryDirectory(prefix="subwave-transport-") as folder, contextlib.ExitStack() as cleanup:
            cleanup.callback(lambda: terminate(fixture))
            cleanup.callback(lambda: terminate(probe))
            cleanup.callback(lambda: terminate(capture))
            temp = Path(folder)
            username, password = "fixture-üser", "fixture-päss:雪"
            authorization = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()
            env.update({"XDG_CONFIG_HOME": str(temp / "config"),
                        "XDG_CACHE_HOME": str(temp / "cache"),
                        "NATIVE_SDK_LOG_DIR": str(temp / "logs"),
                        "PULSE_SINK": sink,
                        "SUBWAVE_TRANSPORT_AUTHORIZATION": authorization,
                        "SUBWAVE_TRANSPORT_SECONDS": "8"})
            fixture_env = env | {"FIXTURE_BASIC_USERNAME": username,
                                 "FIXTURE_BASIC_PASSWORD": password}
            fixture = subprocess.Popen(["node", "station.mjs", "--auth-mode", "basic"],
                                       cwd=fixture_dir, env=fixture_env,
                                       stdout=subprocess.PIPE, text=True)
            # Fixture emits a single credential-free startup record.
            import select
            if not select.select([fixture.stdout], [], [], 10)[0]:
                raise RuntimeError("Fixture startup timed out")
            origins = json.loads(fixture.stdout.readline())
            base = origins["primary"]
            env["SUBWAVE_TRANSPORT_URL"] = base + "/stream.mp3"
            results = []
            for scenario in ("playback", "redirect", "replacement"):
                request(base, "/_fixture/config", {"path": "/stream.mp3",
                                                   "redirect": scenario == "redirect"})
                request(base, "/_fixture/reset", {})
                request(origins["redirect"], "/_fixture/reset", {})
                run_env = env.copy()
                run_env.pop("SUBWAVE_TRANSPORT_REPLACE_URL", None)
                if scenario == "replacement":
                    run_env["SUBWAVE_TRANSPORT_REPLACE_URL"] = env["SUBWAVE_TRANSPORT_URL"]
                log_path = temp / "probe.log"
                with log_path.open("w") as log:
                    probe = subprocess.Popen([str(binary)], env=run_env,
                                             stdout=log, stderr=log)
                    pcm_path = temp / "capture.wav"
                    if scenario == "playback":
                        deadline = time.monotonic() + 5
                        while '"event":"spectrum"' not in log_path.read_text():
                            if probe.poll() is not None or time.monotonic() >= deadline:
                                raise RuntimeError("Native load did not become ready")
                            time.sleep(0.05)
                        inputs = json.loads(subprocess.check_output(
                            ["pactl", "--format=json", "list", "sink-inputs"], env=env, text=True))
                        owned = [item for item in inputs if
                                 item.get("properties", {}).get("application.process.id") == str(probe.pid)]
                        if not owned:
                            raise RuntimeError("Cannot identify probe audio output for capture")
                        for item in owned:
                            subprocess.run(["pactl", "move-sink-input", str(item["index"]), sink],
                                           env=env, check=True)
                        capture = subprocess.Popen([
                            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "pulse", "-i", sink + ".monitor", "-t", "3",
                            "-ac", "1", "-ar", "44100", str(pcm_path)
                        ], env=env)
                    code = probe.wait(timeout=15)
                    if code != 0:
                        raise RuntimeError(f"Probe failed ({code}) in {scenario}")
                    if capture is not None and capture.wait(timeout=5) != 0:
                        raise RuntimeError("PCM capture failed")
                    capture = None
                logs = log_path.read_text()
                if any(secret in logs for secret in (password, authorization, "Authorization")):
                    raise RuntimeError("Credential data appeared in probe logs")
                events = [json.loads(line) for line in logs.splitlines() if line.startswith('{"event":')]
                expected_id = 42 if scenario == "replacement" else 41
                current = [event for event in events if event.get("loadId") == expected_id]
                if scenario == "replacement":
                    assert not any(event.get("loadId") == 41 and event["event"] not in
                                   ("load_requested", "stale_ignored") for event in events)
                if not any(event["event"] == "shutdown" for event in events):
                    raise RuntimeError("Probe did not shut down normally")
                if scenario == "redirect":
                    assert any(event["event"] == "failed" for event in current)
                    assert not any(event["event"] == "loaded" for event in current)
                else:
                    assert any(event["event"] == "loaded" for event in current)
                    assert any(event["event"] == "spectrum" for event in current)
                stats = request(base, "/_fixture/stats")
                assert stats["activeStreams"] == 0, stats
                counter = stats["counters"]["/stream.mp3"]
                assert counter["authorizationPresent"] == counter["requests"] > 0
                assert request(origins["redirect"], "/_fixture/stats")["counters"] == {}
                result = {"mode": "relay", "scenario": scenario,
                          "loadId": expected_id, "activeStreamsAfterStop": 0,
                          "redirectDestinationRequests": 0}
                if scenario == "playback":
                    with wave.open(str(pcm_path)) as pcm:
                        assert pcm.getsampwidth() == 2
                        samples = list(struct.iter_unpack("<h", pcm.readframes(pcm.getnframes())))
                    rms = math.sqrt(sum(value[0] ** 2 for value in samples) / len(samples))
                    db = 20 * math.log10(max(rms, 1) / 32768)
                    assert db > -60, f"Native output was silent: {db} dBFS"
                    result["meanPcmDbfs"] = round(db, 1)
                sentinels = [value.encode() for value in (username, password, authorization,
                                                          authorization.removeprefix("Basic "))]
                for artifact in temp.rglob("*"):
                    if artifact.is_file():
                        data = artifact.read_bytes()
                        if any(value in data for value in sentinels):
                            raise RuntimeError(f"Credential data found in {artifact.relative_to(temp)}")
                results.append(result)
                print(json.dumps(result), flush=True)
            assert len(results) == 3
    finally:
        terminate(capture)
        terminate(probe)
        terminate(fixture)
        subprocess.run(["pactl", "unload-module", module], env=env, check=True)


if __name__ == "__main__":
    main()
