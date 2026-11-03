import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { withRoutePrefix } from "../../lib/routing"
import { PermissionRequestCard } from "../PermissionRequestCard"
import { ActivityState } from "./ActivityState"
import { usePendingApprovals } from "./usePendingApprovals"

/** Approvals tab content. Cards keep their full hierarchy; resolved requests retire as the shared query updates. */
export function ApprovalsActivityPanel({ onNavigate, prefix }: { onNavigate?: () => void; prefix: string }) {
  const { t } = useT("settings")
  const { query, pending } = usePendingApprovals()

  return (
    <div className="space-y-3 p-4">
      {query.isPending ? (
        <ActivityState kind="loading" />
      ) : query.isError && !query.data ? (
        <ActivityState kind="error" message={t("approval_inbox.load_error")} />
      ) : pending.length ? (
        pending.map((request) => <PermissionRequestCard key={request.id} request={request} />)
      ) : (
        <ActivityState kind="empty" message={t("approval_inbox.empty_pending")} />
      )}
      <Link className="inline-block text-sm font-semibold text-brand hover:underline" onClick={onNavigate} to={withRoutePrefix("/permissions/inbox", prefix)}>
        {t("approval_inbox.view_all")}
      </Link>
    </div>
  )
}
