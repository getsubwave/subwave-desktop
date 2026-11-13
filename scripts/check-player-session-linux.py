#!/usr/bin/env python3
"""Exercise public station session playback, native reconnect and station switch."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import urllib.request


def request(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.load(response)


def terminate(process):
    if process.poll() is not None:
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
    env = os.environ.copy()
    if not env.get("XDG_RUNTIME_DIR"):
        raise SystemExit("Run in a Linux desktop session")
    sink = f"subwave_session_check_{os.getpid()}"
    module = subprocess.check_output(["pactl", "load-module", "module-null-sink",
                                      f"sink_name={sink}"], text=True).strip()
    if not module.isdecimal():
        raise RuntimeError("Unexpected Pulse module identifier")
    try:
        with tempfile.TemporaryDirectory(prefix="subwave-session-") as directory, contextlib.ExitStack() as cleanup:
            temp = Path(directory)
            env.update({"XDG_CONFIG_HOME": str(temp / "config"),
                        "XDG_CACHE_HOME": str(temp / "cache"),
                        "NATIVE_SDK_LOG_DIR": str(temp / "logs"), "PULSE_SINK": sink})
            bases = []
            for _ in range(2):
                fixture = subprocess.Popen(["node", "station.mjs"],
                                           cwd=root / "experiments/webview-player/fixtures",
                                           env=env, stdout=subprocess.PIPE, text=True)
                cleanup.callback(terminate, fixture)
                if not select.select([fixture.stdout], [], [], 10)[0]:
                    raise RuntimeError("Fixture startup timeout")
                bases.append(json.loads(fixture.stdout.readline())["primary"])
            for scenario in ("playback", "drop", "switch"):
                for base in bases:
                    request(base, "/_fixture/reset", {})
                run_env = env | {"SUBWAVE_SESSION_FIXTURE": bases[0]}
                run_env.pop("SUBWAVE_SESSION_REPLACEMENT", None)
                if scenario == "switch":
                    run_env["SUBWAVE_SESSION_REPLACEMENT"] = bases[1]
                log_path = temp / f"{scenario}.log"
                with log_path.open("w") as log:
                    probe = subprocess.Popen([str(binary)], env=run_env, stdout=log, stderr=log)
                    cleanup.callback(terminate, probe)
                    deadline = time.monotonic() + 7
                    while '"event":"spectrum"' not in log_path.read_text():
                        if probe.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError("No native spectrum: " + log_path.read_text()[-3000:])
                        time.sleep(0.05)
                    inputs = json.loads(subprocess.check_output(
                        ["pactl", "--format=json", "list", "sink-inputs"], text=True))
                    for item in inputs:
                        if item.get("properties", {}).get("application.process.id") == str(probe.pid):
                            subprocess.run(["pactl", "move-sink-input", str(item["index"]), sink], check=True)
                    if scenario == "drop":
                        request(bases[0], "/_fixture/drop", {})
                    code = probe.wait(timeout=18)
                logs = log_path.read_text()
                events = [json.loads(line) for line in logs.splitlines() if line.startswith('{"event":')]
                assert code == 0, (scenario, code, logs[-3000:])
                final = next(event for event in events if event["event"] == "shutdown")
                if scenario == "playback":
                    assert final["loads"] == 1, final
                elif scenario == "drop":
                    assert final["loads"] >= 2, (final, logs)
                    assert any(e["event"] == "spectrum" and e["loadId"] > 1 for e in events), logs
                else:
                    assert final["loads"] == 2 and final["generation"] == 2, final
                    assert any(e["event"] == "spectrum" and e["generation"] == 2 for e in events), logs
                stats = [request(base, "/_fixture/stats") for base in bases]
                assert all(item["activeStreams"] == 0 for item in stats), stats
                if scenario == "playback":
                    counts = stats[0]["counters"]
                    for endpoint in ("now-playing", "state", "session"):
                        assert counts[f"/api/{endpoint}"]["requests"] >= 2, counts
                    for endpoint in ("themes", "schedule"):
                        assert counts[f"/api/{endpoint}"]["requests"] == 1, counts
                print(json.dumps({"scenario": scenario, "loads": final["loads"],
                                  "generation": final["generation"], "nativeFftSamples": final["samples"],
                                  "activeStreamsAfterStop": 0}), flush=True)
    finally:
        subprocess.run(["pactl", "unload-module", module], check=True)


if __name__ == "__main__":
    main()
