import { describe, expect, test, vi } from "vitest";
import {
  acceptStationSnapshot,
  connectStationBridge,
  createStationBridge,
  parseAccepted,
  parseOperationResult,
  parseStationSnapshot,
  type StationSnapshot,
  type ZeroBridge,
} from "./station-bridge";

function snapshot(generation = 1, revision = 1): StationSnapshot {
  return {
    protocol: 2, revision, generation, playback: "stopped", intent: "stopped", buffering: false,
    volume: 0.8, muted: false, station: null, connection: "none", retry: null, track: null, format: "mp3",
    operations: { station: null, persistence: null }, recents: [],
    preferences: { themeOverride: "", discordEnabled: false, discordClientId: "", notifyTrack: false }, error: null,
  };
}

test("snapshot runtime validation is closed, bounded, and monotonic", () => {
  expect(parseStationSnapshot(snapshot())).not.toBeNull();
  expect(parseStationSnapshot({ ...snapshot(), protocol: 1 })).toBeNull();
  expect(parseStationSnapshot({ ...snapshot(), revision: -1 })).toBeNull();
  expect(parseStationSnapshot({ ...snapshot(), volume: Number.NaN })).toBeNull();
  expect(parseStationSnapshot({ ...snapshot(), recents: Array(9).fill({}) })).toBeNull();
  expect(parseStationSnapshot({ ...snapshot(), preferences: { ...snapshot().preferences, themeOverride: "é".repeat(33) } })).toBeNull();
  const current = snapshot(4, 9);
  expect(acceptStationSnapshot(current, snapshot(4, 8))).toBe(current);
  expect(acceptStationSnapshot(current, snapshot(3, 99))).toBe(current);
  expect(acceptStationSnapshot(current, snapshot(5, 1))).toEqual(snapshot(5, 1));
});

test("accepted and operation results enforce discriminated exact forms", () => {
  expect(parseAccepted({ ok: true, operationId: 41 })).toEqual({ ok: true, operationId: 41 });
  expect(parseAccepted({ ok: false, error: "busy" })).toEqual({ ok: false, error: "busy" });
  expect(parseAccepted({ ok: true, operationId: 0 })).toBeNull();
  expect(parseAccepted({ ok: false, error: "failed" })).toBeNull();
  expect(parseAccepted({ ok: true, operationId: 1, error: "busy" })).toBeNull();
  expect(parseOperationResult({ operationId: 7, status: "failed", errorCode: "offline" })).toEqual({ operationId: 7, status: "failed", errorCode: "offline" });
  expect(parseOperationResult({ operationId: 7, status: "pending" })).toBeNull();
  expect(parseOperationResult({ operationId: Number.MAX_SAFE_INTEGER + 1, status: "failed" })).toBeNull();
});

test("native adapter invokes exact protocol 2 command names and payloads", async () => {
  const invoke = vi.fn(async () => ({ ok: true, operationId: 5 }));
  const bridge = createStationBridge({ invoke, on: vi.fn(() => vi.fn()) });
  await bridge.stationCancel(4);
  await bridge.stationDisconnect();
  await bridge.playbackCommand({ kind: "format", value: "opus" });
  await bridge.preferencesImportLegacy();
  expect(invoke.mock.calls).toEqual([
    ["subwave.player.station.cancel", { operationId: 4 }],
    ["subwave.player.station.disconnect", {}],
    ["subwave.player.playback.command", { kind: "format", value: "opus" }],
    ["subwave.player.preferences.importLegacy", {}],
  ]);
});

describe("subscribe-before-snapshot recovery", () => {
  test("a late initial snapshot cannot overwrite a newer pushed generation", async () => {
    const listeners = new Map<string, (value: unknown) => void>();
    const order: string[] = [];
    let resolveSnapshot!: (value: unknown) => void;
    const initial = new Promise<unknown>((resolve) => { resolveSnapshot = resolve; });
    const zero: ZeroBridge = {
      on(name, listener) { order.push(`on:${name}`); listeners.set(name, listener); return vi.fn(); },
      invoke: vi.fn(async (name) => { order.push(`invoke:${name}`); return initial; }),
    };
    const received: StationSnapshot[] = [];
    connectStationBridge(createStationBridge(zero), (value) => received.push(value));
    expect(order).toEqual(["on:subwave.player.snapshot", "on:subwave.player.operation", "invoke:subwave.player.snapshot"]);
    listeners.get("subwave.player.snapshot")!(snapshot(2, 1));
    resolveSnapshot(snapshot(1, 99));
    await initial;
    await vi.waitFor(() => expect(received).toHaveLength(1));
    expect(received[0]).toEqual(snapshot(2, 1));
  });

  test("snapshot operation recovery and terminal events advance once", async () => {
    const listeners = new Map<string, (value: unknown) => void>();
    const recovered = snapshot();
    recovered.operations.station = { operationId: 41, status: "pending" };
    const zero: ZeroBridge = {
      on(name, listener) { listeners.set(name, listener); return vi.fn(); },
      invoke: vi.fn(async () => recovered),
    };
    const operations: unknown[] = [];
    connectStationBridge(createStationBridge(zero), vi.fn(), (operation) => operations.push(operation));
    await vi.waitFor(() => expect(operations).toEqual([{ operationId: 41, status: "pending" }]));
    listeners.get("subwave.player.operation")!({ operationId: 41, status: "succeeded" });
    listeners.get("subwave.player.operation")!({ operationId: 41, status: "succeeded" });
    listeners.get("subwave.player.operation")!({ operationId: 40, status: "failed" });
    expect(operations).toEqual([{ operationId: 41, status: "pending" }, { operationId: 41, status: "succeeded" }]);
  });

  test("cleanup unsubscribes both channels and suppresses late recovery", async () => {
    let resolveSnapshot!: (value: unknown) => void;
    const pending = new Promise<unknown>((resolve) => { resolveSnapshot = resolve; });
    const stops = [vi.fn(), vi.fn()];
    let index = 0;
    const zero: ZeroBridge = { on: vi.fn(() => stops[index++]), invoke: vi.fn(async () => pending) };
    const receive = vi.fn();
    const stop = connectStationBridge(createStationBridge(zero), receive);
    stop();
    resolveSnapshot(snapshot());
    await pending;
    await Promise.resolve();
    expect(receive).not.toHaveBeenCalled();
    expect(stops[0]).toHaveBeenCalledOnce();
    expect(stops[1]).toHaveBeenCalledOnce();
  });
});

test("an older station operation can finish after a newer persistence operation", async () => {
  const listeners = new Map<string, (value: unknown) => void>();
  const recovered = snapshot();
  recovered.operations.station = { operationId: 41, status: "pending" };
  recovered.operations.persistence = { operationId: 42, status: "pending" };
  const operations: unknown[] = [];
  const zero: ZeroBridge = {
    on(name, listener) { listeners.set(name, listener); return vi.fn(); },
    invoke: vi.fn(async () => recovered),
  };
  const stop = connectStationBridge(createStationBridge(zero), vi.fn(), (op) => operations.push(op));
  await vi.waitFor(() => expect(operations).toHaveLength(2));
  listeners.get("subwave.player.operation")!({ operationId: 42, status: "succeeded" });
  listeners.get("subwave.player.operation")!({ operationId: 41, status: "failed", errorCode: "offline" });
  expect(operations).toHaveLength(4);
  expect(operations[3]).toEqual({ operationId: 41, status: "failed", errorCode: "offline" });
  stop();
});
