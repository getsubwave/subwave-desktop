import { useEffect, useRef, useState } from "react";
import type { Accepted, PreferenceUpdate, StationBridge, StationSnapshot } from "./station-bridge";
import { useOperationCompletion } from "./useOperationCompletion";

const errors: Record<string, string> = {
  vault_unavailable: "Secure storage is unavailable. Unlock it and retry.",
  missing_legacy: "No old settings file was found.",
  no_import: "No old settings file was found.",
  invalid_legacy: "The old settings file could not be read safely.",
  invalid_source: "The old settings file could not be read safely.",
  file_failed: "The settings file could not be saved. Check its location and retry.",
  vault_locked: "Secure storage is locked. Unlock it and retry.",
  vault_denied: "Secure storage access was denied. Allow access and retry.",
  vault_io_failed: "Secure storage is unavailable. Try again.",
  vault_rejected: "Secure storage could not accept the imported credentials.",
  vault_over_bound: "An imported credential exceeds the secure storage limit.",
  verify_failed: "The imported credentials could not be verified in secure storage. Retry import.",
  cancelled: "The preferences operation was cancelled.",
  invalid_request: "That preference value is invalid.",
  busy: "Another preferences operation is still running.",
  unsupported: "That preference is not supported.",
};
const errorText = (code?: string) => code ? errors[code] ?? "The preferences operation failed." : null;

export default function PreferencesPanel({ bridge, snapshot }: { bridge: StationBridge; snapshot: StationSnapshot | null }) {
  const preferences = snapshot?.preferences;
  const operation = snapshot?.operations.persistence ?? null;
  const [theme, setTheme] = useState(preferences?.themeOverride ?? "");
  const [discordId, setDiscordId] = useState(preferences?.discordClientId ?? "");
  const [pendingId, setPendingId] = useState<number | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const submitting = useRef(false);
  const completion = useOperationCompletion(bridge, pendingId, [operation]);

  useEffect(() => setTheme(preferences?.themeOverride ?? ""), [preferences?.themeOverride]);
  useEffect(() => setDiscordId(preferences?.discordClientId ?? ""), [preferences?.discordClientId]);
  useEffect(() => {
    if (completion) {
      submitting.current = false;
      setPendingId(null);
      if (completion.status === "failed") setLocalError(errorText(completion.errorCode));
    }
  }, [completion]);

  const pending = submitting.current || operation?.status === "pending";
  async function run(request: () => Promise<Accepted>) {
    if (submitting.current) return;
    submitting.current = true;
    setLocalError(null);
    try {
      const accepted = await request();
      if (accepted.ok) setPendingId(accepted.operationId);
      else { submitting.current = false; setLocalError(errorText(accepted.error)); }
    } catch { submitting.current = false; setLocalError("Unable to reach the native host."); }
  }
  const update = (value: PreferenceUpdate) => run(() => bridge.preferencesUpdate(value));
  const failed = operation?.status === "failed";
  const visibleError = localError ?? (failed ? errorText(operation.errorCode) : null);

  return <section aria-labelledby="preferences-title">
    <h2 id="preferences-title">Preferences</h2>
    <p>Discord presence and track notifications are not connected in this preview. Their settings are retained.</p>
    {visibleError && <p role="alert">{visibleError}</p>}
    {operation?.status === "pending" && <p aria-live="polite">Saving preferences…</p>}
    <label>Theme override<input aria-label="Theme override" value={theme} onChange={(event) => setTheme(event.currentTarget.value)} /></label>
    <button disabled={pending} onClick={() => void update({ key: "themeOverride", value: theme })}>Save theme</button>
    <label>Discord application ID<input aria-label="Discord application ID" value={discordId} onChange={(event) => setDiscordId(event.currentTarget.value)} /></label>
    <button disabled={pending} onClick={() => void update({ key: "discordClientId", value: discordId })}>Save Discord ID</button>
    <label><input aria-label="Enable Discord presence" type="checkbox" checked={preferences?.discordEnabled ?? false} disabled={!snapshot || pending} onChange={(event) => void update({ key: "discordEnabled", value: event.currentTarget.checked })} /> Enable Discord presence</label>
    <label><input aria-label="Notify when track changes" type="checkbox" checked={preferences?.notifyTrack ?? false} disabled={!snapshot || pending} onChange={(event) => void update({ key: "notifyTrack", value: event.currentTarget.checked })} /> Notify when track changes</label>
    <div><p>Import copies compatible settings into this app. It does not change the old file.</p><button disabled={pending} onClick={() => void run(() => bridge.preferencesImportLegacy())}>{failed ? "Retry import" : "Import old settings"}</button></div>
  </section>;
}
