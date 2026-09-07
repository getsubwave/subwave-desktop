import { useEffect, useRef, useState } from "react";
import { acceptSnapshot, connectSnapshots, nativeBridge, type Bridge, type Command, type Snapshot, type Spectrum, type WindowAction } from "./bridge";

export function SpectrumCanvas({ bridge }: { bridge: Bridge }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  useEffect(() => bridge.subscribeSpectrum((sample: Spectrum) => {
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context) return;
    const ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    if (canvas.width !== width * ratio || canvas.height !== height * ratio) { canvas.width = width * ratio; canvas.height = height * ratio; }
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    const gap = 3;
    const barWidth = (width - gap * 31) / 32;
    context.fillStyle = "#39f5b2";
    sample.bands.forEach((band, index) => {
      const barHeight = Math.max(2, (band / 255) * height);
      context.fillRect(index * (barWidth + gap), height - barHeight, barWidth, barHeight);
    });
  }), [bridge]);
  return <canvas aria-label="Live 32-band spectrum" className="spectrum" ref={canvasRef} />;
}

export default function App({ bridge = nativeBridge }: { bridge?: Bridge }) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const mini = new URLSearchParams(window.location.search).get("view") === "mini";
  useEffect(() => {
    return connectSnapshots(
      bridge,
      (next) => setSnapshot((current) => acceptSnapshot(current, next)),
      (error) => setLocalError(error instanceof Error ? error.message : "Unable to reach native host"),
    );
  }, [bridge]);

  async function issue(command: Command) {
    setLocalError(null);
    try {
      const result = await bridge.command(command);
      if (result.ok) setSnapshot((current) => acceptSnapshot(current, result.snapshot));
      else setLocalError(result.error.replaceAll("_", " "));
    } catch (error) { setLocalError(error instanceof Error ? error.message : "Command failed"); }
  }

  async function issueWindow(action: WindowAction) {
    setLocalError(null);
    try {
      const result = await bridge.window(action);
      if (result.ok) setSnapshot((current) => acceptSnapshot(current, result.snapshot));
      else setLocalError(result.error.replaceAll("_", " "));
    } catch (error) { setLocalError(error instanceof Error ? error.message : "Window command failed"); }
  }

  const disabled = snapshot === null;
  const error = localError ?? snapshot?.error;
  const playing = snapshot?.playback === "playing" || snapshot?.playback === "loading";
  return (
    <main className={mini ? "player mini" : "player"} data-view={mini ? "mini" : "main"}>
      <header><div className="station-mark" aria-hidden="true">S/W</div><div><p className="eyebrow">SUB/WAVE runtime proof</p><h1>{mini ? "Mini player" : "One native session"}</h1></div></header>
      {!mini && <p className="lede">Two React views control one host-owned stream. Audio and spectrum stay native.</p>}
      <SpectrumCanvas bridge={bridge} />
      <section className="status" aria-live="polite"><span>Playback</span><strong>{snapshot?.playback ?? "connecting"}</strong></section>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="transport" aria-label="Playback controls">
        <button disabled={disabled} onClick={() => void issue({ kind: playing ? "pause" : "play" })}>{playing ? "Pause" : "Play"}</button>
        <button disabled={disabled} onClick={() => void issue({ kind: "stop" })}>Stop</button>
      </div>
      <label className="volume"><span>Volume</span><output>{Math.round((snapshot?.volume ?? 0) * 100)}%</output>
        <input aria-label="Volume" disabled={disabled} type="range" min="0" max="1" step="0.01" value={snapshot?.volume ?? 0}
          onChange={(event) => void issue({ kind: "volume", value: event.currentTarget.valueAsNumber })} /></label>
      <div className="windows">{mini
        ? <><button disabled={disabled} onClick={() => void issueWindow("showMain")}>Show main</button><button disabled={disabled} onClick={() => void issueWindow("closeMini")}>Close mini</button></>
        : <><button disabled={disabled} onClick={() => void issueWindow("openMini")}>Open mini</button><button disabled={disabled} onClick={() => void issueWindow("hideMain")}>Hide main</button></>}</div>
    </main>
  );
}
