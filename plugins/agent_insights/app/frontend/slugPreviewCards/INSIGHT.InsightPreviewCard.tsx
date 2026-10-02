import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { Card, Skeleton } from "@app/components/Card"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { TonePill } from "@app/components/StatusPill"
import { useT } from "@app/hooks/useT"
import { renderLightMarkdown } from "@app/lib/Markdown"
import { fetchInsightPreview, type InsightPreviewPayload } from "../api/insights"

type AccessibleInsightPreview = Extract<InsightPreviewPayload["insight"], { accessible: true }>

export function InsightPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("agent_insights")
  const { data, isPending } = useQuery({
    queryKey: ["agent_insights", "preview", String(id)],
    queryFn: () => fetchInsightPreview(id),
    staleTime: 30_000
  })

  if (isPending) return <InsightPreviewSkeleton />
  if (!data) return null

  const insight = data.insight

  if (!insight.accessible) {
    return (
      <Card compact={compact} variant="preview">
        <CopyableSlug className="text-xs" slug={insight.display_id} />
        <p className="mt-2 text-xs text-text-secondary">{t("preview_not_accessible")}</p>
      </Card>
    )
  }

  return (
    <Card compact={compact} variant="preview">
      <div className="mb-2 flex flex-wrap items-center gap-1.5">
        <CopyableSlug className="text-xs" slug={insight.display_id} />
        <SeverityPill severity={insight.severity} />
        <StatePill state={insight.state} />
        <TonePill tone={insight.proposal_type === "remove_memory" ? "red" : "gray"}>{t(`proposal_${insight.proposal_type}`)}</TonePill>
      </div>
      <Link
        className={`mb-2 block text-sm font-medium text-text-primary hover:underline ${compact ? "line-clamp-1" : "line-clamp-2"}`}
        to={insight.web_path}
      >
        {insight.title}
      </Link>
      <div className="mb-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-secondary">
        <Link className="font-mono text-brand-emphasis underline hover:no-underline dark:text-brand-emphasis" to={insight.repository.insights_path}>
          {insight.repository.slug}
        </Link>
        <span>{t("confidence", { pct: Math.round(insight.confidence * 100) })}</span>
        <RelativeTimestamp value={insight.created_at} />
      </div>
      {!compact && insight.summary ? (
        <div className="mb-3 line-clamp-5 break-words text-xs text-text-secondary">{renderLightMarkdown(insight.summary)}</div>
      ) : null}
      {insight.created_job ? (
        <Link className="text-xs text-brand hover:underline dark:text-brand-emphasis" to={insight.created_job.job_path}>
          {t("created_job_label")}: {insight.created_job.slug}
        </Link>
      ) : null}
    </Card>
  )
}

function InsightPreviewSkeleton() {
  return (
    <Card variant="preview">
      <div className="mb-2 flex items-center gap-2">
        <Skeleton className="h-3 w-20" />
        <Skeleton className="h-3 w-12" />
      </div>
      <div className="mb-3 space-y-1.5">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-3/4" />
      </div>
      <div className="space-y-1">
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-2/3" />
      </div>
    </Card>
  )
}

function SeverityPill({ severity }: { severity: AccessibleInsightPreview["severity"] }) {
  const { t } = useT("agent_insights")
  const tone = severity === "high" ? "red" : severity === "medium" ? "amber" : "gray"
  return <TonePill tone={tone}>{t(`severity_${severity}`)}</TonePill>
}

function StatePill({ state }: { state: AccessibleInsightPreview["state"] }) {
  const { t } = useT("agent_insights")
  const tone = state === "accepted" ? "green" : state === "pending" ? "amber" : "gray"
  return <TonePill tone={tone}>{t(`state_${state}`)}</TonePill>
}

export default InsightPreviewCard
