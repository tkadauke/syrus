import { useT } from "../../hooks/useT"
import { TonePill } from "../../components/StatusPill"
import type { JobDetailPayload, JobPrLink, JobPrLinkRole } from "../../api/jobs"

// Job detail "Delivery" panel (EPIC-268): the track/target ref this Job
// lands on, its derived apparent delivery status (richer, PR-number-aware
// copy than the compact dashboard badge — see JobsTable's DeliveryStatusBadge),
// and its PR links grouped by role. The `send_job_upstream` action itself is
// a header action (see JobHeader.tsx's headerActions) — this panel only
// surfaces why it's unavailable, when it is.

const ROLE_ORDER: JobPrLinkRole[] = [ "local", "upstream_export", "promotion", "hotfix_sync", "external_ingest" ]

const UPSTREAM_ROLES = new Set<JobPrLinkRole>([ "promotion", "upstream_export" ])

// The two states every job without delivery config resolves to; skip
// rendering the panel entirely unless there's something beyond that to
// show (a non-default track, a PR link, or a configured send_job_upstream
// action) — mirrors the repository Delivery section's own configured? gate.
export function deliveryPanelRelevant(payload: JobDetailPayload): boolean {
  const { job, pr_links, actions } = payload
  if (job.delivery_track !== "default") return true
  if (pr_links.length > 0) return true
  if (actions.can_send_job_upstream || actions.send_job_upstream_blocked_reason) return true
  return job.delivery_status !== "waiting_for_local_approval" && job.delivery_status !== "approved_for_local_landing"
}

export function DeliveryPanel({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const { job, pr_links } = payload

  return (
    <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("delivery.heading")}</h2>
      <div className="mt-2 space-y-2">
        <div className="flex items-center justify-between">
          <span className="text-gray-500 dark:text-gray-400">{t("delivery.track_label")}</span>
          <span className="font-mono text-xs text-gray-700 dark:text-gray-300">{job.delivery_track}</span>
        </div>
        <div className="flex items-center justify-between">
          <span className="text-gray-500 dark:text-gray-400">{t("delivery.target_ref_label")}</span>
          <span className="font-mono text-xs text-gray-700 dark:text-gray-300">{job.delivery_target_ref}</span>
        </div>
        <div className="flex items-center justify-between">
          <span className="text-gray-500 dark:text-gray-400">{t("delivery.status_label")}</span>
          <TonePill tone={deliveryStatusTone(job.delivery_status)}>{deliveryStatusText(t, job.delivery_status, pr_links)}</TonePill>
        </div>
        {payload.actions.send_job_upstream_blocked_reason ? (
          <p className="text-xs text-gray-400 dark:text-gray-500">{t("delivery.send_upstream_blocked", { reason: payload.actions.send_job_upstream_blocked_reason })}</p>
        ) : null}
        <PrLinksList prLinks={pr_links} />
      </div>
    </div>
  )
}

function PrLinksList({ prLinks }: { prLinks: JobPrLink[] }) {
  const { t } = useT("jobs")
  if (prLinks.length === 0) return null

  const byRole = new Map(prLinks.map((link) => [ link.role, link ]))
  const ordered = ROLE_ORDER.map((role) => byRole.get(role)).filter((link): link is JobPrLink => Boolean(link))

  return (
    <div>
      <span className="text-gray-500 dark:text-gray-400">{t("delivery.pr_links_heading")}</span>
      <ul className="mt-1 divide-y divide-gray-100 dark:divide-gray-800">
        {ordered.map((link) => (
          <li className="flex flex-wrap items-center justify-between gap-1 py-1.5 text-xs" key={link.id}>
            <span className="text-gray-700 dark:text-gray-300">{t(`delivery.role_${link.role}`)}</span>
            <span className="font-mono text-gray-500 dark:text-gray-400">
              {link.source_ref} &rarr; {link.target_repository_slug ? `${link.target_repository_slug}:` : ""}{link.target_ref}
            </span>
            {link.pr_number ? (
              link.pr_url ? (
                <a className="text-brand hover:underline" href={link.pr_url} rel="noreferrer" target="_blank">
                  PR #{link.pr_number}
                </a>
              ) : (
                <span className="text-gray-600 dark:text-gray-300">PR #{link.pr_number}</span>
              )
            ) : null}
            {link.pr_state ? <span className="text-gray-400 dark:text-gray-500">({link.pr_state})</span> : null}
          </li>
        ))}
      </ul>
    </div>
  )
}

function deliveryStatusTone(status: JobDetailPayload["job"]["delivery_status"]): "amber" | "blue" | "green" | "gray" {
  if (status === "delivery_needs_attention" || status === "upstream_closed_without_merge") return "amber"
  if (status === "upstream_merged") return "green"
  if (status === "waiting_for_local_approval") return "gray"
  return "blue"
}

function deliveryStatusText(t: ReturnType<typeof useT>["t"], status: JobDetailPayload["job"]["delivery_status"], prLinks: JobPrLink[]) {
  if (status === "waiting_for_upstream_approval") {
    const link = prLinks.find((candidate) => UPSTREAM_ROLES.has(candidate.role) && candidate.pr_number)
    if (link) return t("delivery.status.waiting_for_upstream_approval", { number: link.pr_number })
    return t("delivery.status.waiting_for_upstream_approval_no_pr")
  }

  return t(`delivery.status.${status}`)
}
