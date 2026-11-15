import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, test, vi } from "vitest";
import App from "./App";
import type { Bridge, Command, Snapshot } from "./bridge";

function fakeBridge(initial: Snapshot) {
  let state = initial;
  const listeners = new Set<(snapshot: Snapshot) => void>();
  const spectrumListeners = new Set<(sample: { generation: number; sequence: number; bands: number[] }) => void>();
  const bridge: Bridge = {
    snapshot: vi.fn(async () => state),
    command: vi.fn(async (command: Command) => {
      const playback = command.kind === "play" ? "playing" : command.kind === "pause" ? "paused" : command.kind === "stop" ? "stopped" : state.playback;
      state = { ...state, revision: state.revision + 1, playback, volume: command.kind === "volume" ? command.value : state.volume };
      listeners.forEach((listener) => listener(state));
      return { ok: true as const, snapshot: state };
    }),
    window: vi.fn(async () => ({ ok: true as const, snapshot: state })),
    subscribe: vi.fn((listener) => { listeners.add(listener); return () => listeners.delete(listener); }),
    subscribeSpectrum: vi.fn((listener) => { spectrumListeners.add(listener); return () => spectrumListeners.delete(listener); }),
  };
  return { bridge, listenerCount: () => listeners.size + spectrumListeners.size };
}

const stopped: Snapshot = { protocol: 1, revision: 0, generation: 1, playback: "stopped", volume: 0.5, error: null };
afterEach(() => { cleanup(); history.replaceState({}, "", "/"); });

describe("player layouts", () => {
  test("main waits for state, sends transport and renders pushed state", async () => {
    const host = fakeBridge(stopped);
    const view = render(<App bridge={host.bridge} />);
    expect(screen.getByRole("button", { name: "Play" })).toBeDisabled();
    await userEvent.click(await screen.findByRole("button", { name: "Play" }));
    expect(host.bridge.command).toHaveBeenCalledWith({ kind: "play" });
    expect(await screen.findByText("playing")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "One native session" })).toBeInTheDocument();
    view.unmount();
    expect(host.listenerCount()).toBe(0);
  });

  test("mini has compact controls and shares host state semantics", async () => {
    history.replaceState({}, "", "/?view=mini");
    const host = fakeBridge({ ...stopped, playback: "playing", revision: 4 });
    render(<App bridge={host.bridge} />);
    await userEvent.click(await screen.findByRole("button", { name: "Pause" }));
    expect(host.bridge.command).toHaveBeenCalledWith({ kind: "pause" });
    expect(screen.queryByText(/Two React views/)).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Show main" }));
    expect(host.bridge.window).toHaveBeenCalledWith("showMain");
    await userEvent.click(screen.getByRole("button", { name: "Close mini" }));
    expect(host.bridge.window).toHaveBeenCalledWith("closeMini");
  });

  test("volume and host errors remain authoritative", async () => {
    const host = fakeBridge({ ...stopped, error: "fixture disconnected" });
    render(<App bridge={host.bridge} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("fixture disconnected");
    const volume = screen.getByRole("slider", { name: "Volume" });
    fireEvent.change(volume, { target: { value: "0.25" } });
    await waitFor(() => expect(host.bridge.command).toHaveBeenCalledWith({ kind: "volume", value: 0.25 }));
  });
});
