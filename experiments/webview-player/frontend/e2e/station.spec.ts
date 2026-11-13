import { expect, test, type BrowserContext } from "@playwright/test";

// Contract evidence only: native audio, vault and files are covered separately.
async function host(context: BrowserContext) {
  await context.addInitScript(() => {
    const stationA = { id: "a".repeat(64), base: "https://a.example", name: "Station A" };
    const initial = { protocol: 2, revision: 1, generation: 1, playback: "paused", intent: "paused", buffering: false,
      volume: .8, muted: false, station: stationA, connection: "ready", retry: null, track: null, format: "mp3",
      operations: { station: null, persistence: null }, recents: [stationA],
      preferences: { themeOverride: "", discordEnabled: false, discordClientId: "", notifyTrack: false }, error: null };
    const listeners = new Map<string, Set<(value: unknown) => void>>();
    const channel = new BroadcastChannel("foundation-contract");
    const emit = (name: string, value: unknown) => listeners.get(name)?.forEach((callback) => callback(value));
    channel.onmessage = (event) => emit(event.data.name, event.data.value);
    const read = () => JSON.parse(localStorage.getItem("foundation-contract") || JSON.stringify(initial));
    const publish = (value: ReturnType<typeof read>) => {
      value.revision++;
      localStorage.setItem("foundation-contract", JSON.stringify(value));
      emit("subwave.player.snapshot", value);
      channel.postMessage({ name: "subwave.player.snapshot", value });
    };
    window.zero = {
      on(name, listener) {
        const set = listeners.get(name) || new Set(); set.add(listener); listeners.set(name, set);
        return () => { set.delete(listener); };
      },
      async invoke(name, input) {
        const payload = input as Record<string, unknown>;
        if (name === "subwave.player.snapshot") return read();
        if (name === "subwave.proof.spectrumAck") return { ok: true };
        if (name === "subwave.proof.window") return { ok: true, snapshot: { protocol: 1, revision: 1, generation: 1, playback: "paused", volume: .8, error: null } };
        const state = read();
        const operationId = Number(localStorage.getItem("foundation-operation") || "1") + 1;
        localStorage.setItem("foundation-operation", String(operationId));
        if (name === "subwave.player.station.cancel") {
          state.operations.station = { operationId: payload.operationId, status: "failed", errorCode: "cancelled" };
          state.connection = "ready"; publish(state);
          return { ok: true, operationId };
        }
        if (name === "subwave.player.station.connect") {
          state.operations.station = { operationId, status: "pending" }; state.connection = "checking"; publish(state);
          const address = String(payload.address);
          setTimeout(() => {
            const current = read();
            if (current.operations.station?.operationId !== operationId || current.operations.station.status !== "pending") return;
            if (address.includes("bad")) current.operations.station = { operationId, status: "failed", errorCode: "health_failed" };
            else {
              current.station = { id: "b".repeat(64), base: address, name: "Station B" }; current.generation++;
              current.operations.station = { operationId, status: "succeeded" };
            }
            current.connection = "ready"; publish(current);
          }, 350);
        } else if (name === "subwave.player.preferences.update") {
          state.preferences[String(payload.key)] = payload.value;
          state.operations.persistence = { operationId: operationId + 100, status: "succeeded" };
          publish(state);
          emit("subwave.player.operation", { operationId, status: "succeeded" });
        } else if (name === "subwave.player.station.forget") {
          state.recents = [];
          state.operations.persistence = { operationId, status: "succeeded" }; publish(state);
          emit("subwave.player.operation", { operationId, status: "succeeded" });
        } else if (name === "subwave.player.preferences.importLegacy") {
          state.operations.persistence = { operationId, status: "failed", errorCode: "no_import" }; publish(state);
        } else if (name === "subwave.player.playback.command") {
          if (payload.kind === "format") {
            // Native terminal events can arrive before the acceptance promise.
            emit("subwave.player.operation", { operationId, status: "failed", errorCode: "UnsupportedFormat" });
            return { ok: true, operationId };
          }
          if (payload.kind === "volume") state.volume = payload.value;
          if (payload.kind === "play" || payload.kind === "pause") {
            state.playback = payload.kind === "play" ? "playing" : "paused"; state.intent = state.playback;
          }
          publish(state);
        }
        return { ok: true, operationId };
      },
    };
  });
}

test("failed station keeps A and successful replacement converges with mini", async ({ context }) => {
  await host(context);
  const main = await context.newPage(); const mini = await context.newPage();
  await main.goto("/?foundation=1"); await mini.goto("/?foundation=1&view=mini");
  await main.getByText("Stations", { exact: true }).first().click();
  await main.getByLabel("Station address").fill("https://bad.example");
  await main.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(main.getByRole("button", { name: "Connect", exact: true })).toBeDisabled();
  await expect(main.getByRole("alert")).toContainText("did not answer");
  await expect(main.getByRole("heading", { name: "Station A" })).toBeVisible();
  await main.getByLabel("Station address").fill("https://b.example");
  await main.getByLabel("Basic credentials").selectOption("replace");
  await main.getByLabel("Basic username").fill("synthetic-user");
  await main.getByLabel("Basic password", { exact: true }).fill("synthetic-password");
  await main.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(main.getByLabel("Basic password", { exact: true })).toHaveValue("");
  await expect(main.getByRole("heading", { name: "Station B" })).toBeVisible();
  await expect(mini.getByRole("heading", { name: "Station B" })).toBeVisible();
  await main.getByRole("slider", { name: "Volume" }).fill("0.25");
  await expect(mini.getByText("25%", { exact: true })).toBeVisible();
  await main.reload();
  await expect(main.getByRole("heading", { name: "Station B" })).toBeVisible();
  await main.screenshot({ path: "/tmp/subwave-foundation-contract.png", fullPage: true });
});

test("accepted playback command still reports native terminal failure", async ({ context, page }) => {
  await host(context); await page.goto("/?foundation=1");
  await page.getByLabel("Stream format").selectOption("opus");
  await expect(page.getByRole("alert")).toHaveText("Unable to apply that player control.");
  await expect(page.getByLabel("Stream format")).toHaveValue("mp3");
});

test("preference receipt and forget completion release their controls", async ({ context, page }) => {
  await host(context); await page.goto("/?foundation=1");
  await page.getByText("Preferences", { exact: true }).first().click();
  await page.getByLabel("Theme override").fill("dawn");
  await page.getByRole("button", { name: "Save theme" }).click();
  await expect(page.getByRole("button", { name: "Save theme" })).toBeEnabled();
  await page.getByText("Stations", { exact: true }).first().click();
  await page.getByRole("button", { name: "Forget Station A" }).click();
  await expect(page.getByText("No recent stations.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Connect", exact: true })).toBeEnabled();
  await expect(page.getByRole("heading", { name: "Station A" })).toBeVisible();
});

test("cancel rejects late activation and import failure remains visible", async ({ context, page }) => {
  await host(context); await page.goto("/?foundation=1");
  await page.getByText("Stations", { exact: true }).first().click();
  await page.getByLabel("Station address").fill("https://b.example");
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await page.getByRole("button", { name: "Cancel connection" }).click();
  await expect(page.getByRole("alert")).toContainText("cancelled");
  await page.waitForTimeout(450);
  await expect(page.getByRole("heading", { name: "Station A" })).toBeVisible();
  await page.getByText("Preferences", { exact: true }).first().click();
  await page.getByRole("button", { name: "Import old settings" }).click();
  await expect(page.getByText("No old settings file was found.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Retry import" })).toBeEnabled();
});
