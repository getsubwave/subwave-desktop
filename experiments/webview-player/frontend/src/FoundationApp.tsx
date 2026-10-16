import { useEffect, useRef, useState } from "react";
import { SpectrumCanvas } from "./App";
import { nativeBridge, type Bridge, type WindowAction } from "./bridge";
import { connectStationBridge, createStationBridge, type Accepted, type OperationStatus, type PlaybackCommand, type StationBridge, type StationSnapshot, type StreamFormat } from "./station-bridge";
import StationPanel from "./StationPanel";
import PreferencesPanel from "./PreferencesPanel";

const connectionLabel = { none: "No station", checking: "Checking station", ready: "Connected", offline: "Offline", "auth-required": "Credentials needed", "vault-unavailable": "Secure storage unavailable", error: "Connection failed" };
const bridge: StationBridge = new Proxy({} as StationBridge, {
  get(_target, name: keyof StationBridge) {
    return (...args: unknown[]) => {
      if (!window.zero) throw new Error("Native bridge is unavailable");
      const method = createStationBridge(window.zero)[name] as (...values: unknown[]) => unknown;
      return method(...args);
    };
  },
});

export default function FoundationApp({ stationBridge = bridge, windowBridge = nativeBridge }: { stationBridge?: StationBridge; windowBridge?: Bridge }) {
  const [snapshot, setSnapshot] = useState<StationSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const controls = useRef(new Set<number>());
  const terminals = useRef(new Map<number, OperationStatus>());
  const mini = new URLSearchParams(window.location.search).get("view") === "mini";
  useEffect(() => connectStationBridge(stationBridge, setSnapshot, (operation) => {
    if (operation.status === "pending") return;
    terminals.current.set(operation.operationId, operation);
    if (terminals.current.size > 16) terminals.current.delete(terminals.current.keys().next().value!);
    if (controls.current.delete(operation.operationId) && operation.status === "failed") setError("Unable to apply that player control.");
  },
    () => setError("Unable to reach the player.")), [stationBridge]);

  function acceptedControl(result: Accepted) {
    if (!result.ok) { setError(result.error === "unsupported" ? "That format is unavailable for this station on this computer." : "Unable to apply that player control."); return; }
    if (result.operationId === undefined) return;
    const completed = terminals.current.get(result.operationId);
    if (completed) { if (completed.status === "failed") setError("Unable to apply that player control."); return; }
    controls.current.add(result.operationId);
    if (controls.current.size > 16) controls.current.delete(controls.current.values().next().value!);
  }

  async function playback(command: PlaybackCommand) {
    setError(null);
    try {
      const result = await stationBridge.playbackCommand(command);
      acceptedControl(result);
    } catch { setError("Unable to reach the player."); }
  }
  async function windowAction(action: WindowAction) {
    try { const result = await windowBridge.window(action); if (!result.ok) setError("Unable to change the player window."); }
    catch { setError("Unable to change the player window."); }
  }
  const playing = snapshot?.intent === "playing";
  const disabled = !snapshot?.station;
  return <main className={mini ? "player mini" : "player foundation"} data-view={mini ? "mini" : "main"}>
    <header><div className="station-mark" aria-hidden="true">S/W</div><div><p className="eyebrow">SUB/WAVE</p><h1>{snapshot?.station?.name || (snapshot?.station ? "Live radio" : "Find your station")}</h1></div></header>
    {snapshot?.station && <p className="station-address">{snapshot.station.base}</p>}
    <SpectrumCanvas bridge={windowBridge} />
    <div className="track"><strong>{snapshot?.track?.title || "Waiting for the next track"}</strong><span>{snapshot?.track?.artist || ""}</span></div>
    <section className="status" aria-live="polite"><span>{snapshot ? connectionLabel[snapshot.connection] : "Connecting"}</span><strong>{snapshot?.buffering ? "Buffering" : snapshot?.playback ?? "Starting"}</strong></section>
    {snapshot?.retry && <p role="status">Reconnecting · attempt {snapshot.retry.attempt}</p>}
    {(error || snapshot?.error) && <p className="error" role="alert">{error || "Playback was interrupted. You can try Play again."}</p>}
    <div className="transport" aria-label="Playback controls"><button disabled={disabled} onClick={() => void playback({ kind: playing ? "pause" : "play" })}>{playing ? "Pause" : "Play"}</button><button disabled={disabled} onClick={() => void playback({ kind: "stop" })}>Stop</button><button disabled={!snapshot} aria-pressed={snapshot?.muted ?? false} onClick={() => void playback({ kind: "mute", value: !snapshot?.muted })}>{snapshot?.muted ? "Unmute" : "Mute"}</button></div>
    <label className="volume"><span>Volume</span><output>{Math.round((snapshot?.volume ?? 0.8) * 100)}%</output><input aria-label="Volume" type="range" min="0" max="1" step="0.01" value={snapshot?.volume ?? 0.8} disabled={!snapshot} onChange={(event) => void playback({ kind: "volume", value: event.currentTarget.valueAsNumber })} /></label>
    {!mini && <label className="format">Stream format<select aria-label="Stream format" disabled={disabled} value={snapshot?.format ?? "mp3"} onChange={(event) => void playback({ kind: "format", value: event.currentTarget.value as StreamFormat })}><option value="mp3">MP3</option><option value="aac">AAC</option><option value="opus">Opus</option><option value="flac">FLAC</option></select></label>}
    <div className="windows">{mini ? <><button onClick={() => void windowAction("showMain")}>Show main</button><button onClick={() => void windowAction("closeMini")}>Close mini</button></> : <><button onClick={() => void windowAction("openMini")}>Open mini</button><button onClick={() => void windowAction("hideMain")}>Hide main</button></>}</div>
    {!mini && <><details open={!snapshot?.station}><summary>Stations</summary><StationPanel bridge={stationBridge} snapshot={snapshot} />{snapshot?.station && <button onClick={() => void stationBridge.stationDisconnect().then(acceptedControl).catch(() => setError("Unable to disconnect."))}>Disconnect</button>}</details><details><summary>Preferences</summary><PreferencesPanel bridge={stationBridge} snapshot={snapshot} /></details></>}
  </main>;
}
