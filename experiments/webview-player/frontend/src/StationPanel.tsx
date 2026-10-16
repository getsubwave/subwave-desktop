import { useEffect, useRef, useState, type FormEvent } from "react";
import type { Accepted, CredentialEdit, StationBridge, StationSnapshot } from "./station-bridge";
import { useOperationCompletion } from "./useOperationCompletion";

type EditAction = CredentialEdit["action"];
const errors: Record<string, string> = {
  offline: "The station is offline.",
  health_failed: "That address did not answer like a SUB/WAVE station.",
  "auth-required": "The station requires credentials.",
  vault_unavailable: "Secure storage is unavailable. Try again.",
  "vault-unavailable": "Secure storage is unavailable. Unlock it and retry.",
  http_consent_required: "Allow insecure HTTP before sending credentials to this station.",
  credentials_invalid: "Check the credential values and try again.",
  listener_auth_required: "Enter this station’s listener password.",
  listener_auth_failed: "The station did not accept the listener password.",
  vault_write_failed: "The credentials could not be saved. Try again.",
  vault_locked: "Secure storage is locked. Unlock it and retry forgetting this station.",
  vault_denied: "Secure storage access was denied. Allow access and retry.",
  vault_io_failed: "Secure storage is unavailable. Retry forgetting this station.",
  vault_rejected: "Secure storage could not remove this station. Try again.",
  save_failed: "The station removal could not be saved. Try again.",
  rate_limited: "The station is receiving too many requests. Wait and retry.",
  forbidden: "The station refused access.",
  redirect_denied: "Enter the station’s final address; redirected connections are not allowed.",
  vault_rollback_failed: "Secure storage could not restore the previous credentials. Retry after unlocking it.",
  cancelled: "Connection cancelled.",
  invalid_request: "Check the station details and try again.",
  busy: "Another station change is still running.",
  unsupported: "That request is not supported.",
};
const errorText = (code?: string) => code ? errors[code] ?? "The station change failed." : null;

export default function StationPanel({ bridge, snapshot }: { bridge: StationBridge; snapshot: StationSnapshot | null }) {
  const [address, setAddress] = useState("");
  const [basicAction, setBasicAction] = useState<EditAction>("keep");
  const [username, setUsername] = useState("");
  const [basicPassword, setBasicPassword] = useState("");
  const [listenerAction, setListenerAction] = useState<EditAction>("keep");
  const [listenerPassword, setListenerPassword] = useState("");
  const [allowHttp, setAllowHttp] = useState(false);
  const [pendingId, setPendingId] = useState<number | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const submitting = useRef(false);
  const operation = snapshot?.operations.station ?? null;
  const completion = useOperationCompletion(bridge, pendingId, [operation, snapshot?.operations.persistence ?? null]);

  useEffect(() => {
    if (completion) {
      submitting.current = false;
      setPendingId(null);
      if (completion.status === "failed") setLocalError(errorText(completion.errorCode));
    }
  }, [completion]);

  const pending = submitting.current || operation?.status === "pending";
  const reportAcceptance = (accepted: Accepted) => {
    if (accepted.ok) setPendingId(accepted.operationId);
    else {
      submitting.current = false;
      setLocalError(errorText(accepted.error));
    }
  };
  const runStationOperation = async (request: () => Promise<Accepted>) => {
    if (submitting.current) return;
    submitting.current = true;
    setLocalError(null);
    try { reportAcceptance(await request()); }
    catch { submitting.current = false; setLocalError("Unable to reach the native host."); }
  };

  async function connect(event: FormEvent) {
    event.preventDefault();
    if (submitting.current) return;
    const target = address.trim();
    if (!target) { setLocalError("Enter a station address."); return; }
    if (/^http:\/\//i.test(target) && !allowHttp) { setLocalError("Allow insecure HTTP before connecting to this address."); return; }
    const basic: CredentialEdit = basicAction === "replace"
      ? { action: "replace", username, password: basicPassword }
      : { action: basicAction };
    const listener = listenerAction === "replace" ? listenerPassword : listenerAction === "clear" ? null : undefined;
    // Secret inputs are transient even when native admission fails.
    setUsername("");
    setBasicPassword("");
    setListenerPassword("");
    await runStationOperation(() => bridge.stationConnect({ address: target, basic, ...(listener === undefined ? {} : { listenerPassword: listener }), allowInsecureHttp: allowHttp }));
  }

  const visibleError = localError ?? (operation?.status === "failed" ? errorText(operation.errorCode) : null);
  return <section aria-labelledby="stations-title">
    <h2 id="stations-title">Stations</h2>
    <p>Now selected: <strong>{snapshot?.station?.name || snapshot?.station?.base || "None"}</strong></p>
    {visibleError && <p role="alert">{visibleError}</p>}
    <form onSubmit={(event) => void connect(event)}>
      <label>Station address<input aria-label="Station address" value={address} onChange={(event) => setAddress(event.currentTarget.value)} /></label>
      <label>Basic credentials<select aria-label="Basic credentials" value={basicAction} onChange={(event) => setBasicAction(event.currentTarget.value as EditAction)}><option value="keep">Keep saved</option><option value="clear">Clear saved</option><option value="replace">Replace</option></select></label>
      {basicAction === "replace" && <><label>Basic username<input aria-label="Basic username" autoComplete="off" value={username} onChange={(event) => setUsername(event.currentTarget.value)} /></label><label>Basic password<input aria-label="Basic password" type="password" autoComplete="new-password" value={basicPassword} onChange={(event) => setBasicPassword(event.currentTarget.value)} /></label></>}
      <label>Listener password action<select aria-label="Listener password action" value={listenerAction} onChange={(event) => setListenerAction(event.currentTarget.value as EditAction)}><option value="keep">Keep saved</option><option value="clear">Clear saved</option><option value="replace">Replace</option></select></label>
      {listenerAction === "replace" && <label>Listener password<input aria-label="Listener password" type="password" autoComplete="new-password" value={listenerPassword} onChange={(event) => setListenerPassword(event.currentTarget.value)} /></label>}
      <label><input aria-label="Allow insecure HTTP" type="checkbox" checked={allowHttp} onChange={(event) => setAllowHttp(event.currentTarget.checked)} /> Allow insecure HTTP for this station</label>
      <button type="submit" disabled={pending}>Connect</button>
      {operation?.status === "pending" && <button type="button" onClick={() => void bridge.stationCancel(operation.operationId)}>Cancel connection</button>}
    </form>
    {snapshot?.recents.length ? <ul aria-label="Recent stations">{snapshot.recents.map((recent) => <li key={recent.id}><span>{recent.name || recent.base}</span> <button disabled={pending} onClick={() => {
      if (recent.base.startsWith("http://")) {
        setAddress(recent.base); setAllowHttp(false);
        setLocalError("Review this HTTP address and explicitly allow insecure HTTP before connecting.");
      } else void runStationOperation(() => bridge.stationConnect({ address: recent.base, basic: { action: "keep" }, allowInsecureHttp: false }));
    }}>Select {recent.name || recent.base}</button> <button disabled={pending} onClick={() => void runStationOperation(() => bridge.stationForget(recent.id))}>Forget {recent.name || recent.base}</button></li>)}</ul> : <p>No recent stations.</p>}
  </section>;
}
