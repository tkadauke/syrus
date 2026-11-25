import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link } from "react-router-dom"
import {
  decidePermissionRequest,
  dismissPermissionRequest,
  fetchPermissionRequest,
  smartDecidePermissionRequest,
  type PermissionRequest,
  type PermissionRequestsPayload,
  type SlimPermissionRequest,
  type SmartPermissionOption
} from "../api/permissionRequests"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Select } from "./Select"
import { PermissionDecisionSummary, permissionActionPhrase, type TechnicalDetail } from "./PermissionDecisionSummary"
import { LinkedPermissionRule, SmartPermissionActions } from "./SmartPermissionActions"

export function PermissionRequestCard({ request, jobId }: { request: PermissionRequest; jobId?: number }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const needsDetail = request.items.some((item) => !("smart_option" in item))
  const detailQuery = useQuery({
    queryKey: ["permission_requests", "detail", request.id],
    queryFn: () => fetchPermissionRequest(request.id),
    enabled: needsDetail && request.state === "pending",
    staleTime: 5 * 60_000
  })
  const displayedRequest = detailQuery.data?.request ?? request
  const durationChoices = displayedRequest.items.reduce<string[]>(
    (choices, item, index) => (index === 0 ? item.requested_durations : choices.filter((choice) => item.requested_durations.includes(choice))),
    []
  )
  const [duration, setDuration] = useState(durationChoices[0] || "invocation")
  const refresh = (resolved?: SlimPermissionRequest) => {
    if (resolved) {
      const wasPending = request.state === "pending"
      const wasBlocked = wasPending && request.checkpoint_state === "waiting"
      queryClient.setQueriesData<PermissionRequestsPayload>(
        {
          predicate: ({ queryKey }) => queryKey[0] === "permission_requests" && queryKey[1] !== "count" && queryKey[1] !== "detail"
        },
        (current) => {
          if (!current) return current
          return {
            ...current,
            requests: current.requests.map((item) => (item.id === resolved.id ? { ...item, ...resolved } : item)),
            summary: {
              pending_count: Math.max(0, current.summary.pending_count - (wasPending ? 1 : 0)),
              blocked_agent_count: Math.max(0, current.summary.blocked_agent_count - (wasBlocked ? 1 : 0))
            }
          }
        }
      )
      queryClient.setQueryData<Pick<PermissionRequestsPayload, "summary">>(["permission_requests", "count"], (current) =>
        current
          ? {
              summary: {
                pending_count: Math.max(0, current.summary.pending_count - (wasPending ? 1 : 0)),
                blocked_agent_count: Math.max(0, current.summary.blocked_agent_count - (wasBlocked ? 1 : 0))
              }
            }
          : current
      )
    }
    void queryClient.invalidateQueries({ queryKey: ["permission_requests"], refetchType: "inactive" })
    if (jobId) void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId), "detail"] })
  }
  const decide = useMutation({
    mutationFn: (decision: "approved" | "denied") => decidePermissionRequest(request.id, decision, decision === "approved" ? duration : undefined),
    onSuccess: ({ request: resolved }) => refresh(resolved)
  })
  const smartItem = displayedRequest.items.find((item) => item.smart_options?.length || item.smart_option)
  const smartDecide = useMutation({
    mutationFn: (option: SmartPermissionOption) => smartDecidePermissionRequest(request.id, smartItem!.id, option),
    onSuccess: ({ request: resolved }) => refresh(resolved)
  })
  const dismiss = useMutation({ mutationFn: () => dismissPermissionRequest(request.id), onSuccess: ({ request: resolved }) => refresh(resolved) })
  const pending = displayedRequest.state === "pending" && displayedRequest.actionable
  const failure = decide.error || dismiss.error
  const linkedAuthority = displayedRequest.items.find((item) => item.resulting_authority)?.resulting_authority

  const summary = displayedRequest.presentation ?? {}
  const technical: TechnicalDetail[] = displayedRequest.items.flatMap((item) => [
    [t("approval_inbox.capability"), [item.capability, item.operation].filter(Boolean).join(" · ")],
    [t("approval_inbox.resource_scope"), item.resource_scope],
    [t("approval_inbox.arguments"), item.arguments]
  ])

  return (
    <article
      className="min-w-0 max-w-full overflow-hidden rounded-xl border border-border bg-surface-raised p-4"
      data-testid={`permission-request-${request.id}`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <span className="rounded bg-warning-surface px-2 py-0.5 text-xs font-medium text-warning-text">{t("approval_inbox.request_badge")}</span>
          <span className="text-xs text-text-muted">
            {request.checkpoint_state || t(`approval_inbox.states.${request.state}`, { defaultValue: request.state })}
          </span>
        </div>
        {request.origin?.type === "Job" ? (
          <Link className="shrink-0 text-xs font-medium text-brand hover:underline" to={`/jobs/${request.origin.id}`}>
            {t("approval_inbox.open_origin")}
          </Link>
        ) : null}
      </div>
      <div className="mt-2">
        <PermissionDecisionSummary
          fallbackStatement={request.purpose || t("approval_inbox.fallback_purpose")}
          headingLevel={2}
          presentation={summary}
          technical={technical}
        />
      </div>
      {pending && smartItem ? (
        <div className="mt-3">
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
            actionPhrase={permissionActionPhrase(smartItem.presentation?.statement || summary.statement)}
            onStale={() => refresh()}
            option={smartItem.smart_option}
            options={smartItem.smart_options}
            request={{ requestId: request.id, itemId: smartItem.id }}
          />
        </div>
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
