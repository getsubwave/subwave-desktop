import { useEffect, useRef, useState } from "react";
import type { OperationStatus, StationBridge } from "./station-bridge";

// The save worker has its own operation ID. The command's terminal event
// acknowledges that command, while snapshots recover station/import status.
export function useOperationCompletion(bridge: StationBridge, pendingId: number | null, recovered: (OperationStatus | null)[]) {
  const terminals = useRef(new Map<number, OperationStatus>());
  const [, changed] = useState(0);
  useEffect(() => bridge.subscribeOperation((operation) => {
    terminals.current.set(operation.operationId, operation);
    if (terminals.current.size > 16) terminals.current.delete(terminals.current.keys().next().value!);
    changed((revision) => revision + 1);
  }), [bridge]);
  if (pendingId === null) return null;
  return terminals.current.get(pendingId) ?? recovered.find((operation) => operation?.operationId === pendingId && operation.status !== "pending") ?? null;
}
