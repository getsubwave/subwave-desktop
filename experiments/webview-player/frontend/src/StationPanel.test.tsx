import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vitest";
import StationPanel from "./StationPanel";
import type { StationBridge, StationSnapshot } from "./station-bridge";

const station = { id: "a".repeat(64), base: "https://playing.example", name: "Playing" };
afterEach(cleanup);
function snapshot(operation: StationSnapshot["operations"]["station"] = null): StationSnapshot {
  return { protocol: 2, revision: 1, generation: 1, playback: "playing", intent: "playing", buffering: false, volume: .8, muted: false, station, connection: "ready", retry: null, track: null, format: "mp3", operations: { station: operation, persistence: null }, recents: [station], preferences: { themeOverride: "", discordEnabled: false, discordClientId: "", notifyTrack: false }, error: null };
}
function bridge(): StationBridge {
  return { snapshot: vi.fn(), stationConnect: vi.fn(async () => ({ ok: true, operationId: 41 })), stationCancel: vi.fn(async () => ({ ok: true, operationId: 41 })), stationForget: vi.fn(async () => ({ ok: true, operationId: 42 })), stationDisconnect: vi.fn(), playbackCommand: vi.fn(), preferencesUpdate: vi.fn(), preferencesImportLegacy: vi.fn(), subscribeSnapshot: vi.fn(() => vi.fn()), subscribeOperation: vi.fn(() => vi.fn()) } as StationBridge;
}

test("requires HTTP consent, submits distinct credential edits, wipes secrets, and guards synchronously", async () => {
  const host = bridge();
  const user = userEvent.setup();
  const view = render(<StationPanel bridge={host} snapshot={snapshot()} />);
  await user.type(screen.getByLabelText("Station address"), "http://radio.example");
  await user.selectOptions(screen.getByLabelText("Basic credentials"), "replace");
  await user.type(screen.getByLabelText("Basic username"), "listener");
  await user.type(screen.getByLabelText("Basic password"), "basic-secret");
  await user.selectOptions(screen.getByLabelText("Listener password action"), "replace");
  await user.type(screen.getByLabelText("Listener password"), "listener-secret");
  await user.click(screen.getByRole("button", { name: "Connect" }));
  expect(host.stationConnect).not.toHaveBeenCalled();
  expect(screen.getByRole("alert")).toHaveTextContent("Allow insecure HTTP");
  await user.click(screen.getByLabelText("Allow insecure HTTP"));
  await user.dblClick(screen.getByRole("button", { name: "Connect" }));
  expect(host.stationConnect).toHaveBeenCalledTimes(1);
  expect(host.stationConnect).toHaveBeenCalledWith({ address: "http://radio.example", basic: { action: "replace", username: "listener", password: "basic-secret" }, listenerPassword: "listener-secret", allowInsecureHttp: true });
  expect(screen.getByLabelText("Basic password")).toHaveValue("");
  expect(screen.getByLabelText("Listener password")).toHaveValue("");
  view.rerender(<StationPanel bridge={host} snapshot={snapshot({ operationId: 41, status: "pending" })} />);
  expect(screen.getByRole("button", { name: "Connect" })).toBeDisabled();
  expect(screen.getAllByText("Playing").length).toBeGreaterThan(0);
});

test("recents connect and forget by stable identity, and pending work can be cancelled", async () => {
  const host = bridge();
  const user = userEvent.setup();
  const { rerender } = render(<StationPanel bridge={host} snapshot={snapshot()} />);
  await user.click(screen.getByRole("button", { name: "Select Playing" }));
  expect(host.stationConnect).toHaveBeenCalledWith({ address: station.base, basic: { action: "keep" }, allowInsecureHttp: false });
  rerender(<StationPanel bridge={host} snapshot={snapshot({ operationId: 41, status: "pending" })} />);
  await user.click(screen.getByRole("button", { name: "Cancel connection" }));
  expect(host.stationCancel).toHaveBeenCalledWith(41);
  rerender(<StationPanel bridge={host} snapshot={snapshot({ operationId: 41, status: "failed", errorCode: "offline" })} />);
  await user.click(screen.getByRole("button", { name: "Forget Playing" }));
  expect(host.stationForget).toHaveBeenCalledWith(station.id);
  expect(screen.getAllByText("Playing").length).toBeGreaterThan(0);
  expect(screen.getByRole("alert")).toHaveTextContent("station is offline");
});
