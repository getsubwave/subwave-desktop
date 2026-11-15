export const PROTOCOL_VERSION = 2 as const;
const MAX_SAFE_ID = Number.MAX_SAFE_INTEGER;
const MAX_BASE_BYTES = 256;
const MAX_NAME_BYTES = 64;
const MAX_TRACK_BYTES = 128;
const MAX_RECENTS = 8;

export type CredentialEdit =
  | { action: "keep" }
  | { action: "clear" }
  | { action: "replace"; username: string; password: string };
export interface Connect {
  address: string;
  basic: CredentialEdit;
  listenerPassword?: string | null;
  allowInsecureHttp: boolean;
}
export type Connection = "none" | "checking" | "ready" | "offline" | "auth-required" | "vault-unavailable" | "error";
export type OperationState = "pending" | "succeeded" | "failed";
export interface OperationStatus { operationId: number; status: OperationState; errorCode?: string }
export type StreamFormat = "mp3" | "aac" | "opus" | "flac";
export type PlaybackCommand =
  | { kind: "play" | "pause" | "stop" }
  | { kind: "volume"; value: number }
  | { kind: "mute"; value: boolean }
  | { kind: "format"; value: StreamFormat };
export type PreferenceUpdate =
  | { key: "themeOverride" | "discordClientId"; value: string }
  | { key: "discordEnabled" | "notifyTrack"; value: boolean };
export interface Station { id: string; base: string; name: string }
export interface Track { id: string; title: string; artist: string; album: string }
export interface StationSnapshot {
  protocol: 2;
  revision: number;
  generation: number;
  playback: "stopped" | "loading" | "playing" | "paused" | "error";
  intent: "stopped" | "playing" | "paused";
  buffering: boolean;
  volume: number;
  muted: boolean;
  station: Station | null;
  connection: Connection;
  retry: { attempt: number; dueInMs: number } | null;
  track: Track | null;
  format: StreamFormat;
  operations: { station: OperationStatus | null; persistence: OperationStatus | null };
  recents: Station[];
  preferences: { themeOverride: string; discordEnabled: boolean; discordClientId: string; notifyTrack: boolean };
  error: { code: string; retryable: boolean } | null;
}
export type AcceptedError = "invalid_request" | "busy" | "unsupported";
export type Accepted = { ok: true; operationId: number } | { ok: false; error: AcceptedError };
export interface OperationResult { operationId: number; status: "succeeded" | "failed"; errorCode?: string }

export interface ZeroBridge {
  invoke(name: string, payload: unknown): Promise<unknown>;
  on(name: string, listener: (detail: unknown) => void): () => void;
}

export interface StationBridge {
  snapshot(): Promise<StationSnapshot>;
  stationConnect(value: Connect): Promise<Accepted>;
  stationCancel(operationId: number): Promise<Accepted>;
  stationForget(id: string): Promise<Accepted>;
  stationDisconnect(): Promise<Accepted>;
  playbackCommand(value: PlaybackCommand): Promise<Accepted>;
  preferencesUpdate(value: PreferenceUpdate): Promise<Accepted>;
  preferencesImportLegacy(): Promise<Accepted>;
  subscribeSnapshot(listener: (snapshot: StationSnapshot) => void): () => void;
  subscribeOperation(listener: (result: OperationResult) => void): () => void;
}

const PLAYBACK = new Set(["stopped", "loading", "playing", "paused", "error"]);
const INTENT = new Set(["stopped", "playing", "paused"]);
const CONNECTION = new Set(["none", "checking", "ready", "offline", "auth-required", "vault-unavailable", "error"]);
const FORMAT = new Set(["mp3", "aac", "opus", "flac"]);
const OPERATION_STATE = new Set(["pending", "succeeded", "failed"]);
const ACCEPTED_ERROR = new Set(["invalid_request", "busy", "unsupported"]);
const encoder = new TextEncoder();

const record = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const safeId = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= MAX_SAFE_ID;
const safeCounter = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= MAX_SAFE_ID;
const bounded = (value: unknown, max: number): value is string => typeof value === "string" && encoder.encode(value).length <= max;
const enumValue = <T extends string>(value: unknown, values: Set<string>): value is T => typeof value === "string" && values.has(value);

function parseStation(value: unknown): Station | null {
  if (!record(value) || typeof value.id !== "string" || !/^[0-9a-f]{64}$/.test(value.id) ||
      !bounded(value.base, MAX_BASE_BYTES) || !bounded(value.name, MAX_NAME_BYTES)) return null;
  return { id: value.id, base: value.base, name: value.name };
}

function parseOperationStatus(value: unknown): OperationStatus | null {
  if (!record(value) || !safeId(value.operationId) || !enumValue<OperationState>(value.status, OPERATION_STATE) ||
      !(value.errorCode === undefined || bounded(value.errorCode, MAX_NAME_BYTES))) return null;
  return { operationId: value.operationId, status: value.status, ...(value.errorCode === undefined ? {} : { errorCode: value.errorCode }) };
}

export function parseOperationResult(value: unknown): OperationResult | null {
  const status = parseOperationStatus(value);
  if (!status || status.status === "pending") return null;
  return status as OperationResult;
}

export function parseAccepted(value: unknown): Accepted | null {
  if (!record(value)) return null;
  if (value.ok === true && safeId(value.operationId) && value.error === undefined) return { ok: true, operationId: value.operationId };
  if (value.ok === false && value.operationId === undefined && enumValue<AcceptedError>(value.error, ACCEPTED_ERROR)) return { ok: false, error: value.error };
  return null;
}

export function parseStationSnapshot(value: unknown): StationSnapshot | null {
  if (!record(value) || value.protocol !== PROTOCOL_VERSION || !safeCounter(value.revision) || !safeCounter(value.generation) ||
      !enumValue<StationSnapshot["playback"]>(value.playback, PLAYBACK) || !enumValue<StationSnapshot["intent"]>(value.intent, INTENT) ||
      typeof value.buffering !== "boolean" || typeof value.volume !== "number" || !Number.isFinite(value.volume) || value.volume < 0 || value.volume > 1 ||
      typeof value.muted !== "boolean" || !enumValue<Connection>(value.connection, CONNECTION) || !enumValue<StreamFormat>(value.format, FORMAT)) return null;
  const station = value.station === null ? null : parseStation(value.station);
  if (value.station !== null && !station) return null;
  let retry: StationSnapshot["retry"] = null;
  if (value.retry !== null) {
    if (!record(value.retry) || !Number.isInteger(value.retry.attempt) || (value.retry.attempt as number) < 0 ||
        (value.retry.attempt as number) > 0xffff_ffff || !safeCounter(value.retry.dueInMs)) return null;
    retry = { attempt: value.retry.attempt as number, dueInMs: value.retry.dueInMs };
  }
  let track: Track | null = null;
  if (value.track !== null) {
    if (!record(value.track) || !bounded(value.track.id, MAX_TRACK_BYTES) || !bounded(value.track.title, MAX_TRACK_BYTES) ||
        !bounded(value.track.artist, MAX_TRACK_BYTES) || !bounded(value.track.album, MAX_TRACK_BYTES)) return null;
    track = { id: value.track.id, title: value.track.title, artist: value.track.artist, album: value.track.album };
  }
  if (!record(value.operations)) return null;
  const stationOperation = value.operations.station === null ? null : parseOperationStatus(value.operations.station);
  const persistenceOperation = value.operations.persistence === null ? null : parseOperationStatus(value.operations.persistence);
  if ((value.operations.station !== null && !stationOperation) || (value.operations.persistence !== null && !persistenceOperation)) return null;
  if (!Array.isArray(value.recents) || value.recents.length > MAX_RECENTS) return null;
  const recents = value.recents.map(parseStation);
  if (recents.some((item) => item === null)) return null;
  if (!record(value.preferences) || !bounded(value.preferences.themeOverride, MAX_NAME_BYTES) || typeof value.preferences.discordEnabled !== "boolean" ||
      !bounded(value.preferences.discordClientId, MAX_NAME_BYTES) || typeof value.preferences.notifyTrack !== "boolean") return null;
  let error: StationSnapshot["error"] = null;
  if (value.error !== null) {
    if (!record(value.error) || !bounded(value.error.code, MAX_NAME_BYTES) || typeof value.error.retryable !== "boolean") return null;
    error = { code: value.error.code, retryable: value.error.retryable };
  }
  return {
    protocol: 2, revision: value.revision, generation: value.generation, playback: value.playback, intent: value.intent,
    buffering: value.buffering, volume: value.volume, muted: value.muted, station, connection: value.connection, retry, track,
    format: value.format, operations: { station: stationOperation, persistence: persistenceOperation }, recents: recents as Station[],
    preferences: { themeOverride: value.preferences.themeOverride, discordEnabled: value.preferences.discordEnabled, discordClientId: value.preferences.discordClientId, notifyTrack: value.preferences.notifyTrack }, error,
  };
}

export function acceptStationSnapshot(current: StationSnapshot | null, value: unknown): StationSnapshot | null {
  const next = parseStationSnapshot(value);
  if (!next) return current;
  if (current && (next.generation < current.generation || (next.generation === current.generation && next.revision <= current.revision))) return current;
  return next;
}

function requireAccepted(value: unknown): Accepted {
  const parsed = parseAccepted(value);
  if (!parsed) throw new Error("Native host returned an invalid operation acceptance");
  return parsed;
}

export function createStationBridge(zero: ZeroBridge): StationBridge {
  const invoke = async (name: string, payload: unknown) => requireAccepted(await zero.invoke(name, payload));
  return {
    async snapshot() {
      const parsed = parseStationSnapshot(await zero.invoke("subwave.player.snapshot", {}));
      if (!parsed) throw new Error("Native host returned an invalid station snapshot");
      return parsed;
    },
    stationConnect: (value) => invoke("subwave.player.station.connect", value),
    stationCancel: (operationId) => invoke("subwave.player.station.cancel", { operationId }),
    stationForget: (id) => invoke("subwave.player.station.forget", { id }),
    stationDisconnect: () => invoke("subwave.player.station.disconnect", {}),
    playbackCommand: (value) => invoke("subwave.player.playback.command", value),
    preferencesUpdate: (value) => invoke("subwave.player.preferences.update", value),
    preferencesImportLegacy: () => invoke("subwave.player.preferences.importLegacy", {}),
    subscribeSnapshot: (listener) => zero.on("subwave.player.snapshot", (detail) => { const parsed = parseStationSnapshot(detail); if (parsed) listener(parsed); }),
    subscribeOperation: (listener) => zero.on("subwave.player.operation", (detail) => { const parsed = parseOperationResult(detail); if (parsed) listener(parsed); }),
  };
}

export function connectStationBridge(
  bridge: StationBridge,
  onSnapshot: (snapshot: StationSnapshot) => void,
  onOperation: (operation: OperationStatus) => void = () => undefined,
  onError: (error: unknown) => void = () => undefined,
): () => void {
  let active = true;
  let current: StationSnapshot | null = null;
  const pendingOperations = new Set<number>();
  const completedOperations = new Set<number>();
  let highestOperation = 0;
  const acceptOperation = (operation: OperationStatus | null) => {
    if (!active || !operation) return;
    const id = operation.operationId;
    if (completedOperations.has(id)) return;
    if (operation.status === "pending") {
      if (pendingOperations.has(id) || pendingOperations.size >= 4) return;
      pendingOperations.add(id);
    } else {
      if (id < highestOperation && !pendingOperations.has(id)) return;
      pendingOperations.delete(id);
      completedOperations.add(id);
      if (completedOperations.size > 16) completedOperations.delete(completedOperations.values().next().value!);
    }
    highestOperation = Math.max(highestOperation, id);
    onOperation(operation);
  };
  const accept = (value: unknown) => {
    if (!active) return;
    const next = acceptStationSnapshot(current, value);
    if (next === current || !next) return;
    current = next;
    onSnapshot(next);
    const recovered = [next.operations.station, next.operations.persistence]
      .filter((operation): operation is OperationStatus => operation !== null)
      .sort((a, b) => a.operationId - b.operationId);
    for (const operation of recovered) acceptOperation(operation);
  };
  // Subscribe first so a state change between subscription and recovery cannot be lost.
  const stopSnapshot = bridge.subscribeSnapshot(accept);
  const stopOperation = bridge.subscribeOperation((operation) => {
    if (!active) return;
    acceptOperation(operation);
  });
  void bridge.snapshot().then(accept).catch((error: unknown) => { if (active) onError(error); });
  return () => { active = false; stopOperation(); stopSnapshot(); };
}
