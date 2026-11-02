import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import { decidePermissionRequest, dismissPermissionRequest, type PermissionRequest, type PermissionRequestsPayload } from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Select } from "./Select"

export function PermissionRequestCard({ request, jobId }: { request: PermissionRequest; jobId?: number }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const durationChoices = request.items.reduce<string[]>(
    (choices, item, index) => (index === 0 ? item.requested_durations : choices.filter((choice) => item.requested_durations.includes(choice))),
    []
  )
  const [duration, setDuration] = useState(durationChoices[0] || "invocation")
  const refresh = (resolved?: PermissionRequest) => {
    if (resolved) {
      queryClient.setQueriesData<PermissionRequestsPayload>({ queryKey: ["permission_requests"] }, (current) => {
        if (!current) return current
        const wasPending = request.state === "pending"
        const wasBlocked = wasPending && request.checkpoint_state === "waiting"
        return {
          ...current,
          requests: current.requests.map((item) => (item.id === resolved.id ? resolved : item)),
          summary: {
            pending_count: Math.max(0, current.summary.pending_count - (wasPending ? 1 : 0)),
            blocked_agent_count: Math.max(0, current.summary.blocked_agent_count - (wasBlocked ? 1 : 0))
          }
        }
      })
    }
    void queryClient.invalidateQueries({ queryKey: ["permission_requests"] })
    if (jobId) void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId), "detail"] })
  }
  const decide = useMutation({
    mutationFn: (decision: "approved" | "denied") => decidePermissionRequest(request.id, decision, decision === "approved" ? duration : undefined),
    onSuccess: ({ request: resolved }) => refresh(resolved)
  })
  const dismiss = useMutation({ mutationFn: () => dismissPermissionRequest(request.id), onSuccess: ({ request: resolved }) => refresh(resolved) })
  const pending = request.state === "pending" && request.actionable
  const failure = decide.error || dismiss.error

  return (
    <article className="rounded-xl border border-border bg-surface-raised p-4" data-testid={`permission-request-${request.id}`}>
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded bg-warning-surface px-2 py-0.5 text-xs font-medium text-warning-text">{t("approval_inbox.request_badge")}</span>
            <span className="text-xs text-text-muted">
              {request.checkpoint_state || t(`approval_inbox.states.${request.state}`, { defaultValue: request.state })}
            </span>
          </div>
          <h2 className="mt-2 font-semibold text-text-primary">{request.purpose || t("approval_inbox.fallback_purpose")}</h2>
          <p className="mt-1 text-xs text-text-secondary">
            {request.subject?.label || request.runtime_role || t("approval_inbox.unknown_subject")}
            {request.origin ? ` · ${request.origin.label}` : ""}
          </p>
        </div>
        {request.origin?.type === "Job" ? (
          <Link className="text-xs font-medium text-brand hover:underline" to={`/jobs/${request.origin.id}`}>
            {t("approval_inbox.open_origin")}
          </Link>
        ) : null}
      </div>
      <div className="mt-3 space-y-3">
        {request.items.map((item) => (
          <div className="rounded-lg bg-surface-subtle p-3 text-sm" key={item.id || `${item.capability}:${item.operation}`}>
            <div className="font-medium text-text-primary">
              {item.capability}
              {item.operation ? ` / ${item.operation}` : ""}
            </div>
            <dl className="mt-2 grid gap-1 text-xs text-text-secondary sm:grid-cols-2">
              <Detail label={t("approval_inbox.resource")} value={`${item.resource_type || "—"} · ${json(item.resource_scope)}`} />
              <Detail label={t("approval_inbox.effects")} value={(item.effects ?? []).join(", ") || "—"} />
              <Detail label={t("approval_inbox.arguments")} value={json(item.arguments)} />
              <Detail label={t("approval_inbox.policy")} value={json(item.decisive_rule)} />
            </dl>
          </div>
        ))}
      </div>
      {pending ? (
        <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-border pt-3">
          {durationChoices.length ? (
            <Select aria-label={t("approval_inbox.duration")} fullWidth={false} onChange={(event) => setDuration(event.target.value)} value={duration}>
              {durationChoices.map((choice) => (
                <option key={choice} value={choice}>
                  {t(`approval_inbox.durations.${choice}`, { defaultValue: choice })}
                </option>
              ))}
            </Select>
          ) : null}
          <button
            className="rounded-md bg-brand px-3 py-1.5 text-sm font-semibold text-on-brand"
            disabled={decide.isPending}
            onClick={() => decide.mutate("approved")}
          >
            {t("approval_inbox.approve")}
          </button>
          <button
            className="rounded-md border border-danger px-3 py-1.5 text-sm font-semibold text-danger"
            disabled={decide.isPending}
            onClick={() => decide.mutate("denied")}
          >
            {t("approval_inbox.deny")}
          </button>
        </div>
      ) : request.actionable ? (
        <button className="mt-3 text-xs font-medium text-text-secondary hover:underline" onClick={() => dismiss.mutate()}>
          {t("approval_inbox.dismiss")}
        </button>
      ) : null}
      {failure ? <p className="mt-2 text-xs text-danger">{errorMessage(failure, t("approval_inbox.action_error"))}</p> : null}
    </article>
  )
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="font-medium text-text-muted">{label}</dt>
      <dd className="break-words text-text-secondary">{value}</dd>
    </div>
  )
}
function json(value: unknown) {
  return value && typeof value === "object" && Object.keys(value as object).length ? JSON.stringify(value) : "—"
}
