#!/usr/bin/env python3
"""Exercise the packaged protocol-2 foundation app through Native automation."""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time
import urllib.request
import wave
import struct


def terminate(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def http_json(base, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=3) as response:
        return json.load(response)


def wait_fixture_counter(base, path, field="successes", minimum=1, timeout=25):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = http_json(base, "/_fixture/stats")
        if last["counters"].get(path, {}).get(field, 0) >= minimum:
            return last
        time.sleep(0.05)
    raise RuntimeError(f"fixture counter did not reach {path}.{field}>={minimum}: {last}")


def start_fixture(root, environment, cleanup, mode="public", username=None,
                  password=None, listener=None):
    fixture_environment = environment.copy()
    if username is not None:
        fixture_environment["FIXTURE_BASIC_USERNAME"] = username
    if password is not None:
        fixture_environment["FIXTURE_BASIC_PASSWORD"] = password
    if listener is not None:
        fixture_environment["FIXTURE_LISTENER_PASSWORD"] = listener
    process = subprocess.Popen(["node", "station.mjs", "--auth-mode", mode],
                               cwd=root / "experiments/webview-player/fixtures",
                               env=fixture_environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    cleanup.callback(terminate, process)
    if not select.select([process.stdout], [], [], 10)[0]:
        raise RuntimeError("station fixture startup timed out")
    line = process.stdout.readline()
    try:
        origins = json.loads(line)
    except json.JSONDecodeError as error:
        details = process.stderr.read() if process.poll() is not None else ""
        raise RuntimeError(f"invalid fixture startup record: {line!r} {details}") from error
    return process, origins["primary"]


class Automation:
    def __init__(self, executable, cwd, environment, timeout, log_path=None):
        self.executable = executable
        self.cwd = cwd
        self.environment = environment
        self.timeout = timeout
        self.sequence = 0
        self.log_path = log_path

    def run(self, *arguments, timeout=None):
        result = subprocess.run([self.executable, "automate", *arguments], cwd=self.cwd,
                                env=self.environment, text=True, capture_output=True,
                                timeout=timeout or self.timeout)
        if result.returncode:
            snapshot = self.cwd / ".zig-cache/native-sdk-automation/snapshot.txt"
            tail = snapshot.read_text(errors="replace")[-3000:] if snapshot.exists() else "<no snapshot>"
            app_tail = (self.log_path.read_text(errors="replace")[-3000:]
                        if self.log_path is not None and self.log_path.exists() else "<no app log>")
            raise RuntimeError(f"native automate {' '.join(arguments)} failed:\n{result.stdout}{result.stderr}\n{tail}\napp log:\n{app_tail}")
        return result.stdout

    def bridge(self, command, payload, allow_overwrite=False):
        self.sequence += 1
        identifier = f"foundation-{self.sequence}"
        request = json.dumps({"id": identifier, "command": command,
                              "payload": payload}, separators=(",", ":"))
        retry_read = command in ("subwave.player.snapshot", "subwave.proof.diagnostics")
        deadline = time.monotonic() + self.timeout
        last = None
        while time.monotonic() < deadline:
            output = self.run("bridge", request)
            records = []
            for line in output.splitlines():
                start = line.find("{")
                if start < 0:
                    continue
                try:
                    value = json.loads(line[start:])
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    records.append(value)
            response_path = self.cwd / ".zig-cache/native-sdk-automation/bridge-response.txt"
            if response_path.exists():
                try:
                    records.append(json.loads(response_path.read_text()))
                except json.JSONDecodeError:
                    pass
            for response in reversed(records):
                last = response
                if response.get("ok") is False:
                    if response.get("id") == identifier:
                        raise RuntimeError(f"bridge transport rejected {command}: {response}")
                    continue
                if "result" not in response:
                    continue
                result = response["result"]
                # WebView-originated snapshot and spectrum ACK responses share
                # the SDK response slot. Identify the requested closed result
                # shape; the outer id can already have been overwritten.
                if self.matches(command, result):
                    return result
            if not retry_read:
                if allow_overwrite:
                    return None
                raise RuntimeError(f"mutating bridge receipt was overwritten; command was not replayed: {command}; last={last}")
            time.sleep(0.02)
        raise RuntimeError(f"bridge response was repeatedly overwritten; command={command} last={last}")

    @staticmethod
    def matches(command, result):
        if not isinstance(result, dict):
            return False
        if command == "subwave.player.snapshot":
            return result.get("protocol") == 2 and "revision" in result
        if command == "subwave.proof.diagnostics":
            return "loadCount" in result and "maxPendingPerView" in result
        if command == "subwave.proof.window":
            return result.get("ok") is False or "snapshot" in result
        if command.startswith("subwave.player."):
            return (result.get("ok") is False or "operationId" in result)
        return False

    def snapshot(self):
        return self.bridge("subwave.player.snapshot", {})

    def wait_snapshot(self, predicate, description):
        deadline = time.monotonic() + self.timeout
        last = None
        while time.monotonic() < deadline:
            last = self.snapshot()
            if predicate(last):
                return last
            time.sleep(0.1)
        raise RuntimeError(f"timed out waiting for {description}; last snapshot={last}")


def accepted(result, command):
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise RuntimeError(f"{command} was not accepted: {result}")
    return result.get("operationId")


def playback(automation, kind, description):
    result = automation.bridge("subwave.player.playback.command", {"kind": kind},
                               allow_overwrite=True)
    if result is not None:
        accepted(result, description)


def window_action(automation, action):
    result = automation.bridge("subwave.proof.window", {"action": action},
                               allow_overwrite=True)
    if result is not None and result.get("ok") is not True:
        raise RuntimeError(f"window action failed: {action}: {result}")


def begin_operation(automation, command, payload, group, description):
    prior = automation.snapshot().get("operations", {}).get(group)
    prior_id = prior.get("operationId") if isinstance(prior, dict) else None
    result = automation.bridge(command, payload, allow_overwrite=True)
    if result is not None:
        return accepted(result, description)
    snapshot = automation.wait_snapshot(
        lambda value: isinstance(value.get("operations", {}).get(group), dict) and
        value["operations"][group].get("operationId") != prior_id,
        f"receipt recovery for {description}")
    return snapshot["operations"][group]["operationId"]


def station_base(snapshot):
    station = snapshot.get("station")
    return station.get("base") if isinstance(station, dict) else None


def wait_operation(automation, operation_id, group):
    def completed(snapshot):
        operation = snapshot.get("operations", {}).get(group)
        return (isinstance(operation, dict) and
                operation.get("operationId") == operation_id and
                operation.get("status") != "pending")
    snapshot = automation.wait_snapshot(completed, f"{group} operation {operation_id}")
    operation = snapshot["operations"][group]
    if operation["status"] != "succeeded":
        raise RuntimeError(f"{group} operation failed: {operation}")
    return snapshot


def wait_persistence_after(automation, operation_id):
    def completed(snapshot):
        status = snapshot.get("operations", {}).get("persistence")
        return (isinstance(status, dict) and status.get("operationId", 0) > operation_id
                and status.get("status") == "succeeded")
    return automation.wait_snapshot(completed, f"persistence after operation {operation_id}")


def connect_payload(base, mode="public", username=None, password=None,
                    listener=None, allow_http=True):
    basic = ({"action": "replace", "username": username, "password": password}
             if mode in ("basic", "combined") else {"action": "clear"})
    result = {"address": base, "basic": basic,
              "allowInsecureHttp": allow_http}
    if mode in ("listener", "combined"):
        result["listenerPassword"] = listener
    elif mode != "public":
        result["listenerPassword"] = None
    return result


def prepare_resources(resources, cwd):
    if resources is None:
        return
    source = resources.resolve(strict=True)
    candidates = [source / "frontend/dist", source / "dist", source]
    dist = next((candidate for candidate in candidates if (candidate / "index.html").is_file()), None)
    if dist is None:
        raise RuntimeError(f"--resources has no frontend dist/index.html: {source}")
    target = cwd / "frontend"
    target.mkdir()
    os.symlink(dist, target / "dist", target_is_directory=True)


def capture_pcm(sink, destination, environment):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "pulse", "-i", sink + ".monitor", "-t", "2",
                    "-ac", "1", "-ar", "44100", str(destination)],
                   env=environment, check=True, timeout=8)
    with wave.open(str(destination)) as pcm:
        if pcm.getsampwidth() != 2:
            raise RuntimeError("unexpected PCM sample width")
        samples = [sample[0] for sample in struct.iter_unpack("<h", pcm.readframes(pcm.getnframes()))]
    if not samples:
        raise RuntimeError("native audio capture contained no PCM samples")
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    dbfs = 20 * math.log10(max(rms, 1) / 32768)
    if dbfs <= -60:
        raise RuntimeError(f"combined private station output was silent: {dbfs:.1f} dBFS")
    return round(dbfs, 1)


def move_owned_audio(process_id, sink, environment, timeout=5):
    deadline = time.monotonic() + timeout
    owned = []
    while time.monotonic() < deadline and not owned:
        inputs = json.loads(subprocess.check_output(
            ["pactl", "--format=json", "list", "sink-inputs"], env=environment, text=True))
        owned = [item for item in inputs
                 if item.get("properties", {}).get("application.process.id") == str(process_id)]
        if not owned:
            time.sleep(0.05)
    if not owned:
        raise RuntimeError("could not identify the foundation app's PulseAudio sink input after playback")
    for item in owned:
        subprocess.run(["pactl", "move-sink-input", str(item["index"]), sink],
                       env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--resources", type=Path,
                        help="resource root or frontend dist for an unpackaged binary")
    parser.add_argument("--native", default="native", help="Native SDK CLI executable")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    if not os.environ.get("XDG_RUNTIME_DIR"):
        raise SystemExit("Run in a Linux desktop session with XDG_RUNTIME_DIR set")
    binary = args.binary.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    if not (root / "experiments/webview-player/fixtures/tone.mp3").is_file():
        raise SystemExit("Missing fixture tone.mp3; run experiments/webview-player/fixtures/generate-tone.sh")
    native = shutil.which(args.native)
    if native is None:
        raise SystemExit(f"Native SDK CLI not found: {args.native}")

    environment = os.environ.copy()
    environment.pop("SUBWAVE_STATION_URL", None)
    environment.pop("NATIVE_SDK_FRONTEND_URL", None)
    sink = f"subwave_foundation_check_{os.getpid()}"
    module = subprocess.check_output(["pactl", "load-module", "module-null-sink",
                                      f"sink_name={sink}"], env=environment, text=True).strip()
    if not module.isdecimal():
        raise RuntimeError("unexpected PulseAudio module identifier")
    try:
        with tempfile.TemporaryDirectory(prefix="subwave-foundation-") as folder, contextlib.ExitStack() as cleanup:
            temp = Path(folder)
            prepare_resources(args.resources, temp)
            for name in ("config", "cache", "data", "state", "logs"):
                (temp / name).mkdir()
            (temp / "vault").mkdir()
            environment.update({
                "XDG_CONFIG_HOME": str(temp / "config"),
                "XDG_CACHE_HOME": str(temp / "cache"),
                "XDG_DATA_HOME": str(temp / "data"),
                "XDG_STATE_HOME": str(temp / "state"),
                "NATIVE_SDK_LOG_DIR": str(temp / "logs"),
                "PULSE_SINK": sink,
                "SUBWAVE_TEST_VAULT_DIR": str(temp / "vault"),
            })
            fixture_a, base_a = start_fixture(root, environment, cleanup)
            fixture_b, base_b = start_fixture(root, environment, cleanup)
            secrets = {
                "basic": ("fixture-basic-user", "fixture-basic-secret", None),
                "listener": (None, None, "fixture-listener-secret"),
                "combined": ("fixture-combined-user", "fixture-combined-basic",
                             "fixture-combined-listener"),
            }
            private = {}
            for mode, values in secrets.items():
                process, base = start_fixture(root, environment, cleanup, mode, *values)
                private[mode] = (process, base)
            log_path = temp / "foundation.log"
            with log_path.open("w") as log:
                app = subprocess.Popen([str(binary)], cwd=temp, env=environment,
                                       stdout=log, stderr=log)
            cleanup.callback(terminate, app)
            automation = Automation(native, temp, environment, args.timeout, log_path)
            automation.run("wait")
            raw_snapshot = automation.run("snapshot")
            if "ready=true" not in raw_snapshot or "kind=webview" not in raw_snapshot:
                raise RuntimeError("automation did not report a ready WebView foundation app")
            frontend_deadline = time.monotonic() + args.timeout
            while True:
                frontend_diagnostics = automation.bridge("subwave.proof.diagnostics", {})
                if any(view.get("ready") and view.get("snapshotCount", 0) > 0
                       for view in frontend_diagnostics.get("views", [])):
                    break
                if time.monotonic() >= frontend_deadline:
                    raise RuntimeError(f"React bridge did not subscribe and request its own snapshot: {frontend_diagnostics}")
                time.sleep(0.05)
            initial = automation.snapshot()
            if initial.get("protocol") != 2:
                raise RuntimeError(f"expected station protocol 2: {initial}")
            connect_a = begin_operation(automation, "subwave.player.station.connect", {
                "address": base_a, "basic": {"action": "keep"},
                "allowInsecureHttp": True,
            }, "station", "station.connect")
            if not connect_a:
                raise RuntimeError(f"station.connect omitted its operationId: {connect_a!r}")
            wait_fixture_counter(base_a, "/stream.mp3", timeout=args.timeout)
            playback(automation, "pause", "playback.pause")
            playback(automation, "stop", "stop after pause proof")
            playing_a = automation.wait_snapshot(
                lambda value: station_base(value) == base_a and value.get("playback") == "stopped",
                "stopped first public station after pause")
            playback(automation, "play", "playback.play")
            playback(automation, "pause", "second playback.pause")
            playback(automation, "stop", "second playback.stop")
            automation.wait_snapshot(lambda value: value.get("playback") == "stopped", "second stopped playback")

            http_json(base_b, "/_fixture/config", {"path": "/api/health", "delayMs": 1500})
            candidate = begin_operation(automation, "subwave.player.station.connect", {
                "address": base_b, "basic": {"action": "keep"},
                "allowInsecureHttp": True,
            }, "station", "delayed station.connect")
            automation.bridge("subwave.player.station.cancel", {"operationId": candidate}, allow_overwrite=True)
            automation.wait_snapshot(lambda value: station_base(value) == base_a, "old station retained after cancellation")
            http_json(base_b, "/_fixture/config", {"path": "/api/health", "delayMs": 0})
            begin_operation(automation, "subwave.player.station.connect", {
                "address": base_b, "basic": {"action": "keep"},
                "allowInsecureHttp": True,
            }, "station", "replacement station.connect")
            playback(automation, "play", "play replacement")
            wait_fixture_counter(base_b, "/stream.mp3", timeout=args.timeout)
            playback(automation, "stop", "stop replacement")
            switched = automation.wait_snapshot(lambda value: station_base(value) == base_b and
                                                  value.get("playback") == "stopped", "station switch")
            if switched.get("generation", 0) <= playing_a.get("generation", 0):
                raise RuntimeError("station switch did not advance generation")

            private_results = {}
            combined_pcm_dbfs = None
            for mode, (_, base) in private.items():
                username, password, listener = secrets[mode]
                spectrum_before = automation.bridge("subwave.proof.diagnostics", {})["nativeSpectrumFrames"]
                operation = begin_operation(automation, "subwave.player.station.connect",
                                            connect_payload(base, mode, username,
                                                            password, listener),
                                            "station", f"{mode} station.connect")
                connected = wait_operation(automation, operation, "station")
                playback(automation, "play", f"play {mode}")
                wait_fixture_counter(base, "/stream.mp3", timeout=args.timeout)
                if mode == "combined":
                    time.sleep(1)
                    move_owned_audio(app.pid, sink, environment)
                    combined_pcm_dbfs = capture_pcm(sink, temp / "combined-private.wav", environment)
                playback(automation, "stop", f"stop {mode}")
                automation.wait_snapshot(lambda value, expected=base: station_base(value) == expected and
                                          value.get("playback") == "stopped", f"stopped {mode} playback")
                wait_persistence_after(automation, operation)
                if automation.bridge("subwave.proof.diagnostics", {})["nativeSpectrumFrames"] <= spectrum_before:
                    raise RuntimeError(f"{mode} station produced no new native FFT samples")
                stats = http_json(base, "/_fixture/stats")
                health = stats["counters"].get("/api/health", {})
                stream = stats["counters"].get("/stream.mp3", {})
                if mode in ("basic", "combined"):
                    if health.get("authorizationPresent", 0) != health.get("requests", 0):
                        raise RuntimeError(f"{mode} API requests lacked Basic auth: {stats}")
                    if stream.get("authorizationPresent", 0) != stream.get("requests", 0):
                        raise RuntimeError(f"{mode} stream requests lacked Basic auth: {stats}")
                if mode in ("listener", "combined"):
                    auth = stats["counters"].get("/api/station-auth", {})
                    if auth.get("listenerAuthPresent", 0) < 1 or stream.get("listenerAuthPresent", 0) < 1:
                        raise RuntimeError(f"{mode} listener authentication was not exercised: {stats}")
                private_results[mode] = stats["counters"]

            combined_base = private["combined"][1]
            before_drop = automation.bridge("subwave.proof.diagnostics", {})["loadCount"]
            stream_requests = http_json(combined_base, "/_fixture/stats")["counters"]["/stream.mp3"]["requests"]
            playback(automation, "play", "play before drop")
            wait_fixture_counter(combined_base, "/stream.mp3", "requests", stream_requests + 1,
                                 args.timeout)
            http_json(combined_base, "/_fixture/drop", {})
            wait_fixture_counter(combined_base, "/stream.mp3", "requests", stream_requests + 2,
                                 args.timeout)
            playback(automation, "stop", "stop after drop")
            automation.wait_snapshot(lambda value: station_base(value) == combined_base and
                                      value.get("playback") == "stopped", "stopped full-GUI reconnect")
            if automation.bridge("subwave.proof.diagnostics", {})["loadCount"] < before_drop + 2:
                raise RuntimeError("native audio load count did not advance after stream drop")

            window_action(automation, "openMini")
            automation.run("list")
            window_action(automation, "hideMain")
            automation.run("reload")
            window_action(automation, "showMain")
            diagnostics = automation.bridge("subwave.proof.diagnostics", {})
            if diagnostics.get("maxPendingPerView", 2) > 1:
                raise RuntimeError(f"spectrum backpressure exceeded one pending sample: {diagnostics}")
            if diagnostics.get("mainVisible") is not True or diagnostics.get("miniVisible") is not True:
                raise RuntimeError(f"window visibility state did not converge: {diagnostics}")
            window_action(automation, "closeMini")

            stats = [http_json(base, "/_fixture/stats") for base in (base_a, base_b)]
            print(json.dumps({
                "scenario": "public-foundation",
                "protocol": initial["protocol"],
                "generation": switched["generation"],
                "firstOperationId": connect_a,
                "maxPendingPerView": diagnostics["maxPendingPerView"],
                "fixtureRequests": [item["counters"] for item in stats],
                "privateModes": private_results,
                "combinedPrivatePcmDbfs": combined_pcm_dbfs,
            }), flush=True)
            if app.poll() is not None:
                raise RuntimeError("foundation app exited before verification completed: " + log_path.read_text()[-3000:])
            terminate(app)
            for base in (base_a, base_b):
                deadline = time.monotonic() + 5
                while http_json(base, "/_fixture/stats")["activeStreams"] != 0:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("fixture retained an audio stream after app shutdown")
                    time.sleep(0.05)

            # Exercise legacy import in a fresh settings/vault namespace so a
            # later forget can prove that both records were removed.
            automation_dir = temp / ".zig-cache/native-sdk-automation"
            if automation_dir.exists():
                shutil.rmtree(automation_dir)
            import_config = temp / "import-config"
            import_vault = temp / "import-vault"
            import_vault.mkdir()
            legacy_dir = import_config / "subwave-player"
            new_dir = import_config / "subwave-player-next"
            legacy_dir.mkdir(parents=True)
            new_dir.mkdir(parents=True)
            environment["XDG_CONFIG_HOME"] = str(import_config)
            environment["SUBWAVE_TEST_VAULT_DIR"] = str(import_vault)
            import_user, import_password, import_listener = secrets["combined"]
            legacy_url = combined_base.replace("http://", f"http://{import_user}:{import_password}@", 1)
            legacy_bytes = json.dumps({"station": legacy_url,
                                       "stationName": "Imported Fixture",
                                       "stationPassword": import_listener,
                                       "recents": [{"name": "Imported Public",
                                                    "url": base_a}]},
                                      separators=(",", ":")).encode()
            legacy_path = legacy_dir / "settings.json"
            legacy_path.write_bytes(legacy_bytes)

            import_log = temp / "import.log"
            with import_log.open("w") as log:
                imported_app = subprocess.Popen([str(binary)], cwd=temp, env=environment,
                                                stdout=log, stderr=log)
            cleanup.callback(terminate, imported_app)
            automation = Automation(native, temp, environment, args.timeout, import_log)
            automation.run("wait")
            automation.wait_snapshot(
                lambda value: value.get("operations", {}).get("persistence", {}).get("status") == "succeeded",
                "fresh import namespace cold load")
            import_id = begin_operation(automation, "subwave.player.preferences.importLegacy", {},
                                        "persistence", "preferences.importLegacy")
            imported = wait_operation(automation, import_id, "persistence")
            imported_station = next((station for station in imported.get("recents", [])
                                     if station.get("base") == combined_base), None)
            if imported_station is None:
                raise RuntimeError(f"imported station absent from sanitized recents: {imported}")
            imported_id = imported_station["id"]
            backup_path = new_dir / "settings.legacy.backup.json"
            if not backup_path.is_file() or backup_path.read_bytes() != legacy_bytes:
                raise RuntimeError("legacy backup was not an exact byte-for-byte copy")
            # Imported public HTTP remains usable without credential consent.
            public_import_id = begin_operation(automation, "subwave.player.station.connect", {
                "address": base_a, "basic": {"action": "clear"},
                "listenerPassword": None, "allowInsecureHttp": False,
            }, "station", "imported public HTTP connect")
            wait_operation(automation, public_import_id, "station")
            playback(automation, "play", "play imported public HTTP")
            wait_fixture_counter(base_a, "/stream.mp3", timeout=args.timeout)
            playback(automation, "stop", "stop imported public HTTP")
            wait_persistence_after(automation, public_import_id)

            # The imported private HTTP station must still fail before any
            # request until the user explicitly grants cleartext consent.
            http_json(combined_base, "/_fixture/reset", {})
            denied_id = begin_operation(automation, "subwave.player.station.connect", {
                "address": combined_base, "basic": {"action": "keep"},
                "allowInsecureHttp": False,
            }, "station", "unconsented imported private HTTP connect")
            denied = automation.wait_snapshot(
                lambda value: value.get("operations", {}).get("station", {}).get("operationId") == denied_id and
                value["operations"]["station"].get("status") == "failed",
                "imported private HTTP consent rejection")
            if station_base(denied) != base_a:
                raise RuntimeError(f"failed private candidate replaced the public station: {denied}")
            if http_json(combined_base, "/_fixture/stats")["counters"]:
                raise RuntimeError("unconsented imported HTTP station reached the network")

            consent_id = begin_operation(automation, "subwave.player.station.connect", {
                "address": combined_base, "basic": {"action": "keep"},
                "allowInsecureHttp": True,
            }, "station", "explicit imported station consent")
            consented = wait_operation(automation, consent_id, "station")
            playback(automation, "play", "play consented imported station")
            wait_fixture_counter(combined_base, "/stream.mp3", timeout=args.timeout)
            playback(automation, "stop", "stop consented imported station")
            if station_base(consented) != combined_base:
                consented = automation.wait_snapshot(
                    lambda value: station_base(value) == combined_base,
                    "consented imported station activation")
            wait_persistence_after(automation, consent_id)
            terminate(imported_app)
            http_json(combined_base, "/_fixture/reset", {})

            # Consent and credentials must both survive another launch.
            if automation_dir.exists():
                shutil.rmtree(automation_dir)
            final_log = temp / "import-restart-consented.log"
            with final_log.open("w") as log:
                final_app = subprocess.Popen([str(binary)], cwd=temp, env=environment,
                                             stdout=log, stderr=log)
            cleanup.callback(terminate, final_app)
            automation = Automation(native, temp, environment, args.timeout, final_log)
            automation.run("wait")
            wait_fixture_counter(combined_base, "/stream.mp3", timeout=args.timeout)
            playback(automation, "stop", "stop consented restart")
            resumed = automation.wait_snapshot(
                lambda value: station_base(value) == combined_base and
                value.get("connection") == "ready" and value.get("playback") == "stopped",
                "consented private station restart")
            restart_station_operation = resumed.get("operations", {}).get("station")
            if isinstance(restart_station_operation, dict):
                wait_persistence_after(automation, restart_station_operation["operationId"])
            loads_before_forget = automation.bridge("subwave.proof.diagnostics", {})["loadCount"]
            requests_before_forget = http_json(combined_base, "/_fixture/stats")["counters"]["/stream.mp3"]["requests"]
            playback(automation, "play", "play before active forget")
            wait_fixture_counter(combined_base, "/stream.mp3", "requests",
                                 requests_before_forget + 1, args.timeout)
            if http_json(combined_base, "/_fixture/stats")["activeStreams"] != 1:
                raise RuntimeError("active forget precondition lacked one live stream")
            forget_receipt = automation.bridge("subwave.player.station.forget", {"id": imported_id},
                                               allow_overwrite=True)
            forget_id = accepted(forget_receipt, "station.forget") if forget_receipt is not None else None
            settings_path = new_dir / "settings.v2.json"
            deadline = time.monotonic() + args.timeout
            while True:
                saved = json.loads(settings_path.read_text())
                if saved.get("pendingRemoval") is None and not any(
                        station.get("id") == imported_id for station in saved.get("stations", [])):
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"active forget did not reach durable final save: {saved}")
                time.sleep(0.05)
            after_forget_stats = http_json(combined_base, "/_fixture/stats")
            if after_forget_stats["activeStreams"] != 1:
                raise RuntimeError("forgetting the active station closed its live stream")
            if after_forget_stats["counters"]["/stream.mp3"]["requests"] != requests_before_forget + 1:
                raise RuntimeError("forgetting the active station replaced its stream")
            playback(automation, "stop", "stop after active forget")
            forgotten = automation.wait_snapshot(
                lambda value: not any(station.get("id") == imported_id
                                      for station in value.get("recents", [])), "forgotten snapshot")
            persistence_status = forgotten.get("operations", {}).get("persistence")
            if not isinstance(persistence_status, dict) or persistence_status.get("status") != "succeeded":
                raise RuntimeError(f"forget persistence did not succeed: {forgotten}")
            if forget_id is None:
                forget_id = persistence_status["operationId"]
            if any(station.get("id") == imported_id for station in forgotten.get("recents", [])):
                raise RuntimeError("forgotten station remained in recents")
            if station_base(forgotten) != combined_base:
                raise RuntimeError("forgetting the active station interrupted the live host")
            if automation.bridge("subwave.proof.diagnostics", {})["loadCount"] != loads_before_forget + 1:
                raise RuntimeError("forgetting the active station caused an audio reload")
            if import_vault.exists() and any(path.is_file() for path in import_vault.iterdir()):
                raise RuntimeError("forgotten station retained synthetic vault records")
            terminate(final_app)

            if automation_dir.exists():
                shutil.rmtree(automation_dir)
            absence_log = temp / "forget-restart.log"
            with absence_log.open("w") as log:
                absence_app = subprocess.Popen([str(binary)], cwd=temp, env=environment,
                                               stdout=log, stderr=log)
            cleanup.callback(terminate, absence_app)
            automation = Automation(native, temp, environment, args.timeout, absence_log)
            automation.run("wait")
            absent = automation.wait_snapshot(
                lambda value: value.get("operations", {}).get("persistence", {}).get("status") == "succeeded",
                "post-forget restart")
            if station_base(absent) is not None or any(station.get("id") == imported_id
                                                       for station in absent.get("recents", [])):
                raise RuntimeError(f"forgotten station returned after restart: {absent}")
            terminate(absence_app)

            allowed_secret_files = {legacy_path.resolve(), backup_path.resolve()}
            vault_roots = {(temp / "vault").resolve(), import_vault.resolve()}
            sentinel_bytes = [value.encode() for values in secrets.values()
                              for value in values if value is not None]
            for artifact in temp.rglob("*"):
                if not artifact.is_file():
                    continue
                resolved = artifact.resolve()
                if resolved in allowed_secret_files or any(root == resolved or root in resolved.parents
                                                            for root in vault_roots):
                    continue
                data = artifact.read_bytes()
                if any(sentinel in data for sentinel in sentinel_bytes):
                    raise RuntimeError(f"credential sentinel escaped approved storage: {artifact.relative_to(temp)}")
            print(json.dumps({"scenario": "import-consent-forget-restart",
                              "importOperationId": import_id,
                              "forgetOperationId": forget_id,
                              "activeLoadPreserved": loads_before_forget,
                              "activeStreamsDuringForget": 1,
                              "vaultRecordsAfterForget": 0}), flush=True)
    finally:
        subprocess.run(["pactl", "unload-module", module], env=environment, check=True)


if __name__ == "__main__":
    main()
