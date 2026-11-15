import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vitest";
import PreferencesPanel from "./PreferencesPanel";
import type { StationBridge, StationSnapshot } from "./station-bridge";
afterEach(cleanup);

function snapshot(persistence: StationSnapshot["operations"]["persistence"] = null): StationSnapshot {
  return { protocol: 2, revision: 1, generation: 0, playback: "stopped", intent: "stopped", buffering: false, volume: .8, muted: false, station: null, connection: "none", retry: null, track: null, format: "mp3", operations: { station: null, persistence }, recents: [], preferences: { themeOverride: "night", discordEnabled: true, discordClientId: "123456789012345678", notifyTrack: true }, error: null };
}
function bridge(): StationBridge {
  return { subscribeOperation: vi.fn(() => vi.fn()), preferencesUpdate: vi.fn(async () => ({ ok: true, operationId: 50 })), preferencesImportLegacy: vi.fn(async () => ({ ok: true, operationId: 51 })) } as unknown as StationBridge;
}

test("retained controls submit closed updates and import remains pending until authoritative completion", async () => {
  const host = bridge();
  const user = userEvent.setup();
  const view = render(<PreferencesPanel bridge={host} snapshot={snapshot()} />);
  expect(screen.getByLabelText("Theme override")).toHaveValue("night");
  expect(screen.getByLabelText("Enable Discord presence")).toBeChecked();
  expect(screen.getByLabelText("Notify when track changes")).toBeChecked();
  await user.clear(screen.getByLabelText("Theme override"));
  await user.type(screen.getByLabelText("Theme override"), "dawn");
  await user.click(screen.getByRole("button", { name: "Save theme" }));
  expect(host.preferencesUpdate).toHaveBeenCalledWith({ key: "themeOverride", value: "dawn" });
  view.rerender(<PreferencesPanel bridge={host} snapshot={snapshot({ operationId: 50, status: "pending" })} />);
  expect(screen.getByText("Saving preferences…")).toBeInTheDocument();
  view.rerender(<PreferencesPanel bridge={host} snapshot={snapshot({ operationId: 50, status: "succeeded" })} />);
  await user.click(screen.getByRole("button", { name: "Import old settings" }));
  expect(host.preferencesImportLegacy).toHaveBeenCalledTimes(1);
  expect(screen.getByText(/does not change the old file/i)).toBeInTheDocument();
});

test("failed import is reported truthfully and offers retry", async () => {
  const host = bridge();
  const user = userEvent.setup();
  render(<PreferencesPanel bridge={host} snapshot={snapshot({ operationId: 51, status: "failed", errorCode: "vault_unavailable" })} />);
  expect(screen.getByRole("alert")).toHaveTextContent(/secure storage is unavailable/i);
  await user.click(screen.getByRole("button", { name: "Retry import" }));
  expect(host.preferencesImportLegacy).toHaveBeenCalledTimes(1);
});
