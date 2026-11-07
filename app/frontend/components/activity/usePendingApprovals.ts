import { useQuery } from "@tanstack/react-query"
import { fetchPermissionRequests } from "../../api/permissionRequests"

/** Shared by the desktop drawer trigger, the mobile Activity tabs and the panel so every surface reads one cache entry. */
export function usePendingApprovals() {
  const query = useQuery({
    queryKey: ["permission_requests", "summary"],
    queryFn: () => fetchPermissionRequests(1, "", "summary"),
    staleTime: 0,
    refetchInterval: 30_000
  })
  const pending = (query.data?.requests ?? []).filter((request) => request.state === "pending")
  const pendingCount = query.data?.summary?.pending_count ?? pending.length
  const blockedCount = query.data?.summary?.blocked_agent_count ?? pending.filter((request) => request.checkpoint_state === "waiting").length
  return { query, pending, pendingCount, blockedCount }
}
