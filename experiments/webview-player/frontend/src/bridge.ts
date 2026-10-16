export type Playback = "stopped" | "loading" | "playing" | "paused" | "error";
export interface Snapshot { protocol: 1; revision: number; generation: number; playback: Playback; volume: number; error: string | null }
export type Command = { kind: "play" } | { kind: "pause" } | { kind: "stop" } | { kind: "volume"; value: number };
export type Result = { ok: true; snapshot: Snapshot } | { ok: false; error: "invalid_request" | "unsupported" | "failed" };
export type Spectrum = { generation: number; sequence: number; bands: number[] };
export type WindowAction = "openMini" | "closeMini" | "hideMain" | "showMain";
export interface Bridge {
  snapshot(): Promise<Snapshot>;
  command(command: Command): Promise<Result>;
  window(action: WindowAction): Promise<Result>;
  subscribe(listener: (snapshot: Snapshot) => void): () => void;
  subscribeSpectrum(listener: (spectrum: Spectrum) => void): () => void;
}

export function connectSnapshots(
  bridge: Bridge,
  listener: (snapshot: Snapshot) => void,
  onError: (error: unknown) => void = () => undefined,
): () => void {
  let active = true;
  let current: Snapshot | null = null;
  let pendingRefresh: Promise<void> | null = null;
  let refreshRequested = false;

  const accept = (next: unknown) => {
    if (!active) return;
    const accepted = acceptSnapshot(current, next);
    if (accepted !== current) {
      current = accepted;
      if (accepted) listener(accepted);
    }
  };

  const refresh = () => {
    if (!active) return;
    if (pendingRefresh) {
      refreshRequested = true;
      return;
    }
    refreshRequested = false;
    pendingRefresh = bridge.snapshot()
      .then(accept)
      .catch((error: unknown) => { if (active) onError(error); })
      .finally(() => {
        pendingRefresh = null;
        if (active && refreshRequested) refresh();
      });
  };

  const unsubscribe = bridge.subscribe((next) => {
    const gap = current !== null && next.generation === current.generation && next.revision > current.revision + 1;
    accept(next);
    if (gap) refresh();
  });
  refresh();

  return () => {
    active = false;
    unsubscribe();
  };
}

interface ZeroBridge { invoke(name: string, payload: unknown): Promise<unknown>; on(name: string, listener: (detail: unknown) => void): () => void }
declare global { interface Window { zero?: ZeroBridge } }

const PLAYBACK = new Set<Playback>(["stopped", "loading", "playing", "paused", "error"]);
const ERRORS = new Set(["invalid_request", "unsupported", "failed"]);
const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const isIndex = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

export function parseSnapshot(value: unknown): Snapshot | null {
  if (!isRecord(value) || value.protocol !== 1 || !isIndex(value.revision) || !isIndex(value.generation) ||
      typeof value.playback !== "string" || !PLAYBACK.has(value.playback as Playback) ||
      typeof value.volume !== "number" || !Number.isFinite(value.volume) || value.volume < 0 || value.volume > 1 ||
      !(value.error === null || typeof value.error === "string")) return null;
  return value as unknown as Snapshot;
}

export function acceptSnapshot(current: Snapshot | null, next: unknown): Snapshot | null {
  const parsed = parseSnapshot(next);
  if (!parsed) return current;
  if (!current) return parsed;
  if (parsed.generation < current.generation) return current;
  if (parsed.generation === current.generation && parsed.revision <= current.revision) return current;
  return parsed;
}

export function parseSpectrum(value: unknown): Spectrum | null {
  if (!isRecord(value) || !isIndex(value.generation) || !isIndex(value.sequence) || !Array.isArray(value.bands) ||
      value.bands.length !== 32 || !value.bands.every((band) => Number.isInteger(band) && band >= 0 && band <= 255)) return null;
  return value as unknown as Spectrum;
}

function parseResult(value: unknown): Result {
  if (isRecord(value) && value.ok === true) {
    const snapshot = parseSnapshot(value.snapshot);
    if (snapshot) return { ok: true, snapshot };
  }
  if (isRecord(value) && value.ok === false && typeof value.error === "string" && ERRORS.has(value.error)) {
    return { ok: false, error: value.error as "invalid_request" | "unsupported" | "failed" };
  }
  throw new Error("Native host returned an invalid result");
}

function getZero(): ZeroBridge {
  if (!window.zero) throw new Error("Native bridge is unavailable");
  return window.zero;
}

export function createNativeBridge(zero: ZeroBridge = getZero()): Bridge {
  return {
    async snapshot() {
      const parsed = parseSnapshot(await zero.invoke("subwave.proof.snapshot", {}));
      if (!parsed) throw new Error("Native host returned an invalid snapshot");
      return parsed;
    },
    async command(command) { return parseResult(await zero.invoke("subwave.proof.command", command)); },
    async window(action) { return parseResult(await zero.invoke("subwave.proof.window", { action })); },
    subscribe(listener) {
      return zero.on("subwave.proof.snapshot", (detail) => { const parsed = parseSnapshot(detail); if (parsed) listener(parsed); });
    },
    subscribeSpectrum(listener) {
      let latest: Spectrum | null = null;
      return zero.on("subwave.proof.spectrum", (detail) => {
        const parsed = parseSpectrum(detail);
        if (!parsed) return;
        if (!latest || parsed.generation > latest.generation ||
            (parsed.generation === latest.generation && parsed.sequence > latest.sequence)) {
          latest = parsed;
          listener(parsed);
        }
        void zero.invoke("subwave.proof.spectrumAck", { sequence: parsed.sequence }).catch(() => undefined);
      });
    },
  };
}

export const nativeBridge: Bridge = {
  snapshot: () => createNativeBridge().snapshot(), command: (command) => createNativeBridge().command(command),
  window: (action) => createNativeBridge().window(action), subscribe: (listener) => createNativeBridge().subscribe(listener),
  subscribeSpectrum: (listener) => createNativeBridge().subscribeSpectrum(listener),
};
