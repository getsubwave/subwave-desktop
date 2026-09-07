import { expect, test, type BrowserContext } from "@playwright/test";

async function installFakeHost(context: BrowserContext) {
  await context.addInitScript(() => {
    const initial = { protocol: 1, revision: 0, generation: 1, playback: "stopped", volume: 0.5, error: null };
    const listeners = new Map<string, Set<(detail: unknown) => void>>();
    const channel = new BroadcastChannel("subwave-proof-host");
    const read = () => JSON.parse(localStorage.getItem("proof-state") ?? JSON.stringify(initial));
    const publish = (state: unknown) => {
      localStorage.setItem("proof-state", JSON.stringify(state));
      channel.postMessage(state);
      listeners.get("subwave.proof.snapshot")?.forEach((listener) => listener(state));
    };
    channel.onmessage = (event) => listeners.get("subwave.proof.snapshot")?.forEach((listener) => listener(event.data));
    Object.defineProperty(window, "__proofListenerCount", { get: () => [...listeners.values()].reduce((sum, set) => sum + set.size, 0) });
    window.zero = {
      on(name, callback) {
        const set = listeners.get(name) ?? new Set();
        set.add(callback);
        listeners.set(name, set);
        return () => { set.delete(callback); if (!set.size) listeners.delete(name); };
      },
      async invoke(name, payload) {
        if (name === "subwave.proof.snapshot") return read();
        if (name === "subwave.proof.spectrumAck") return { ok: true };
        if (name === "subwave.proof.window") return { ok: true, snapshot: read() };
        if (name === "subwave.proof.command") {
          const command = payload as { kind: string; value?: number };
          const old = read();
          const playback = command.kind === "play" ? "playing" : command.kind === "pause" ? "paused" : command.kind === "stop" ? "stopped" : old.playback;
          const next = { ...old, revision: old.revision + 1, playback, volume: command.kind === "volume" ? command.value : old.volume };
          publish(next);
          return { ok: true, snapshot: next };
        }
        return { ok: false, error: "unsupported" };
      },
    };
  });
}

test("main and mini converge on one fake host session", async ({ context }) => {
  await installFakeHost(context);
  const main = await context.newPage();
  const mini = await context.newPage();
  await main.goto("/");
  await mini.goto("/?view=mini");
  await expect(main.getByRole("button", { name: "Play" })).toBeEnabled();
  await main.getByRole("button", { name: "Play" }).click();
  await expect(mini.getByText("playing", { exact: true })).toBeVisible();
  await mini.getByRole("button", { name: "Pause" }).click();
  await expect(main.getByText("paused", { exact: true })).toBeVisible();
  await main.getByRole("slider", { name: "Volume" }).fill("0.25");
  await expect(mini.getByText("25%", { exact: true })).toBeVisible();
  expect(await mini.evaluate(() => (window as unknown as { __proofListenerCount: number }).__proofListenerCount)).toBe(2);
  await mini.getByRole("button", { name: "Close mini" }).click();
  await mini.close();
  await main.getByRole("button", { name: "Play" }).click();
  await expect(main.getByText("playing", { exact: true })).toBeVisible();
});

test("invalid host snapshots keep controls unavailable", async ({ context }) => {
  await context.addInitScript(() => { window.zero = { on: () => () => {}, invoke: async () => ({ protocol: 2 }) }; });
  const page = await context.newPage();
  await page.goto("/");
  await expect(page.getByRole("alert")).toContainText("invalid snapshot");
  await expect(page.getByRole("button", { name: "Play" })).toBeDisabled();
});
