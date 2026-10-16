import { describe, expect, test, vi } from "vitest";
import { acceptSnapshot, connectSnapshots, createNativeBridge, parseSpectrum, type Bridge, type Snapshot } from "./bridge";

const current: Snapshot = { protocol: 1, generation: 2, revision: 9, playback: "paused", volume: 0.5, error: null };

test("late snapshots do not rewind playback", () => {
  expect(acceptSnapshot(current, { ...current, revision: 8, playback: "playing" })).toBe(current);
});

test("an old generation cannot win with a larger revision", () => {
  expect(acceptSnapshot(current, { ...current, generation: 1, revision: 99 })).toBe(current);
});

test("rejects unsupported protocols and malformed durable fields", () => {
  expect(acceptSnapshot(current, { ...current, protocol: 2 })).toBe(current);
  expect(acceptSnapshot(current, { ...current, volume: Number.NaN })).toBe(current);
  expect(acceptSnapshot(current, { ...current, revision: 9 })).toBe(current);
});

test("a new generation may restart its revision", () => {
  const next = { ...current, generation: 3, revision: 0, playback: "playing" as const };
  expect(acceptSnapshot(current, next)).toEqual(next);
});

test("spectrum requires exactly 32 integer byte bands", () => {
  const valid = { generation: 2, sequence: 4, bands: Array(32).fill(128) };
  expect(parseSpectrum(valid)).toEqual(valid);
  expect(parseSpectrum({ ...valid, bands: Array(31).fill(1) })).toBeNull();
  expect(parseSpectrum({ ...valid, bands: [...Array(31).fill(1), 256] })).toBeNull();
  expect(parseSpectrum({ ...valid, bands: [...Array(31).fill(1), 1.5] })).toBeNull();
});

describe("native subscriptions", () => {
  test("filters malformed and duplicate spectrum, acknowledges delivery, and cleans up", async () => {
    const listeners = new Map<string, (detail: unknown) => void>();
    const unsubscribe = vi.fn();
    const invoke = vi.fn(async () => ({ ok: true }));
    const bridge = createNativeBridge({ invoke, on: (name, listener) => { listeners.set(name, listener); return unsubscribe; } });
    const receive = vi.fn();
    const stop = bridge.subscribeSpectrum(receive);
    const emit = listeners.get("subwave.proof.spectrum")!;
    emit({ generation: 1, sequence: 2, bands: Array(32).fill(2) });
    emit({ generation: 1, sequence: 2, bands: Array(32).fill(3) });
    emit({ generation: 1, sequence: 3, bands: [1] });
    expect(receive).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(invoke).toHaveBeenLastCalledWith("subwave.proof.spectrumAck", { sequence: 2 });
    stop();
    expect(unsubscribe).toHaveBeenCalledOnce();
  });

  test("snapshot subscribe uses the SDK event name and returned cleanup", () => {
    const unsubscribe = vi.fn();
    const on = vi.fn(() => unsubscribe);
    const bridge = createNativeBridge({ invoke: vi.fn(), on });
    expect(bridge.subscribe(vi.fn())).toBe(unsubscribe);
    expect(on).toHaveBeenCalledWith("subwave.proof.snapshot", expect.any(Function));
  });
});

describe("snapshot recovery", () => {
  function deferred<T>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((done) => { resolve = done; });
    return { promise, resolve };
  }

  function recoveryBridge(initial: Promise<Snapshot>) {
    let pushed: ((snapshot: Snapshot) => void) | undefined;
    const unsubscribe = vi.fn();
    const bridge = {
      snapshot: vi.fn(() => initial),
      subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => { pushed = listener; return unsubscribe; }),
    } as unknown as Bridge;
    return { bridge, push: (snapshot: Snapshot) => pushed!(snapshot), unsubscribe };
  }

  test("a same-generation revision gap starts one bounded refresh", async () => {
    const initial = deferred<Snapshot>();
    const host = recoveryBridge(initial.promise);
    const receive = vi.fn();
    connectSnapshots(host.bridge, receive);
    initial.resolve(current);
    await vi.waitFor(() => expect(receive).toHaveBeenCalledOnce());

    const refresh = deferred<Snapshot>();
    vi.mocked(host.bridge.snapshot).mockReturnValueOnce(refresh.promise);
    host.push({ ...current, revision: 11, playback: "playing" });
    host.push({ ...current, revision: 13, playback: "stopped" });
    expect(host.bridge.snapshot).toHaveBeenCalledTimes(2);
    refresh.resolve({ ...current, revision: 13, playback: "stopped" });
    await refresh.promise;
  });

  test("a startup gap latched behind the initial request gets one follow-up refresh", async () => {
    const initial = deferred<Snapshot>();
    const refresh = deferred<Snapshot>();
    const host = recoveryBridge(initial.promise);
    const received: Snapshot[] = [];
    connectSnapshots(host.bridge, (snapshot) => received.push(snapshot));
    vi.mocked(host.bridge.snapshot).mockReturnValueOnce(refresh.promise);

    host.push({ ...current, revision: 9, playback: "paused" });
    host.push({ ...current, revision: 11, playback: "playing" });
    expect(host.bridge.snapshot).toHaveBeenCalledOnce();

    initial.resolve({ ...current, revision: 8, playback: "loading" });
    await vi.waitFor(() => expect(host.bridge.snapshot).toHaveBeenCalledTimes(2));
    expect(received.map(({ revision }) => revision)).toEqual([9, 11]);

    refresh.resolve({ ...current, revision: 12, playback: "playing" });
    await vi.waitFor(() => expect(received.map(({ revision }) => revision)).toEqual([9, 11, 12]));
    expect(host.bridge.snapshot).toHaveBeenCalledTimes(2);
  });

  test("a refresh response cannot overwrite a later pushed revision", async () => {
    const initial = deferred<Snapshot>();
    const host = recoveryBridge(initial.promise);
    const received: Snapshot[] = [];
    connectSnapshots(host.bridge, (snapshot) => received.push(snapshot));
    initial.resolve(current);
    await vi.waitFor(() => expect(received).toHaveLength(1));

    const refresh = deferred<Snapshot>();
    vi.mocked(host.bridge.snapshot).mockReturnValueOnce(refresh.promise);
    host.push({ ...current, revision: 11, playback: "playing" });
    host.push({ ...current, revision: 12, playback: "stopped" });
    refresh.resolve({ ...current, revision: 10, playback: "loading" });
    await refresh.promise;
    await Promise.resolve();
    expect(received.map(({ revision }) => revision)).toEqual([9, 11, 12]);
    expect(received.at(-1)?.playback).toBe("stopped");
  });

  test("unsubscribing suppresses a late initial snapshot", async () => {
    const initial = deferred<Snapshot>();
    const host = recoveryBridge(initial.promise);
    const receive = vi.fn();
    const stop = connectSnapshots(host.bridge, receive);
    stop();
    initial.resolve(current);
    await initial.promise;
    await Promise.resolve();
    expect(receive).not.toHaveBeenCalled();
    expect(host.unsubscribe).toHaveBeenCalledOnce();
  });
});
