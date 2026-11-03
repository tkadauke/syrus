import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import {
  decidePermissionRequest,
  dismissPermissionRequest,
  smartDecidePermissionRequest,
  type PermissionRequest,
  type PermissionRequestsPayload,
  type SmartPermissionOption
} from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Select } from "./Select"
import { LinkedPermissionRule, SmartPermissionActions } from "./SmartPermissionActions"

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
  const smartItem = request.items.find((item) => item.smart_option)
  const smartDecide = useMutation({
    mutationFn: (option: SmartPermissionOption) => smartDecidePermissionRequest(request.id, smartItem!.id, option),
    onSuccess: ({ request: resolved }) => refresh(resolved)
  })
  const dismiss = useMutation({ mutationFn: () => dismissPermissionRequest(request.id), onSuccess: ({ request: resolved }) => refresh(resolved) })
  const pending = request.state === "pending" && request.actionable
  const failure = decide.error || dismiss.error
  const linkedAuthority = request.items.find((item) => item.resulting_authority)?.resulting_authority

  const summary = request.presentation ?? {}
  const context = [summary.agent, summary.origin].filter((value): value is string => Boolean(value))
  const details = (
    [
      [t("approval_inbox.scope"), summary.scope],
      [t("approval_inbox.consequence"), summary.consequences?.join(", ")],
      [t("approval_inbox.requested_duration"), summary.requested_durations?.join(", ")],
      [t("approval_inbox.why_required"), summary.why_approval_required]
    ] as Array<[string, string | undefined]>
  ).filter((entry): entry is [string, string] => Boolean(entry[1]))

  return (
    <article
      className="min-w-0 max-w-full overflow-hidden rounded-xl border border-border bg-surface-raised p-4"
      data-testid={`permission-request-${request.id}`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded bg-warning-surface px-2 py-0.5 text-xs font-medium text-warning-text">{t("approval_inbox.request_badge")}</span>
            <span className="text-xs text-text-muted">
              {request.checkpoint_state || t(`approval_inbox.states.${request.state}`, { defaultValue: request.state })}
            </span>
          </div>
          <h2 className="mt-2 break-words font-semibold text-text-primary">{summary.statement || request.purpose || t("approval_inbox.fallback_purpose")}</h2>
          {context.length ? <p className="mt-1 break-words text-xs text-text-secondary">{context.join(" · ")}</p> : null}
        </div>
        {request.origin?.type === "Job" ? (
          <Link className="shrink-0 text-xs font-medium text-brand hover:underline" to={`/jobs/${request.origin.id}`}>
            {t("approval_inbox.open_origin")}
          </Link>
        ) : null}
      </div>
      {details.length ? (
        <dl className="mt-3 min-w-0 space-y-1 rounded-lg bg-surface-subtle p-3 text-xs text-text-secondary">
          {details.map(([label, value]) => (
            <div className="min-w-0" key={label}>
              <dt className="font-medium text-text-muted">{label}</dt>
              <dd className="[overflow-wrap:anywhere]">{value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {pending && smartItem ? (
        <SmartPermissionActions
          busy={decide.isPending || smartDecide.isPending}
          error={smartDecide.error || decide.error}
          onAllowOnce={() => {
            smartDecide.reset()
            decide.mutate("approved")
          }}
          onConfirm={(option) => smartDecide.mutate(option)}
          onDeny={() => {
            smartDecide.reset()
            decide.mutate("denied")
          }}
          onCustomized={(decision) => {
            smartDecide.reset()
            decide.mutate(decision)
          }}
          onStale={() => refresh()}
          option={smartItem.smart_option}
          request={{ requestId: request.id, itemId: smartItem.id }}
        />
      ) : pending ? (
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
      {linkedAuthority ? (
        <div className="mt-2">
          <LinkedPermissionRule authority={linkedAuthority} />
        </div>
      ) : null}
      {failure && !(pending && smartItem) ? <p className="mt-2 text-xs text-danger">{errorMessage(failure, t("approval_inbox.action_error"))}</p> : null}
    </article>
  )
}
