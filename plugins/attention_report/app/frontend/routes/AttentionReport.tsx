import { Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { fetchAttentionReport, type AttentionFigure, type AttentionPageStatistic } from "../api/attentionReport"

const WINDOWS = [7, 30] as const
const DECIDING_RULES = ["human_created_jobs", "messages_before_confirmed_proposals", "proposal_edits", "proposal_discards"]
const JUDGING_RULES = ["job_approvals", "pr_review_comments", "feedback_workflows", "active_review_page_time"]
const WASTED_RULES = [
  "human_retry_rebase_ci_repair_reruns",
  "landing_blocker_overrides",
  "landing_blocker_rechecks_and_wakes",
  "reapproval_after_base_change_unchanged_diff"
]

export default function AttentionReportRoute() {
  const { t } = useT("attention_report")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const [windowDays, setWindowDays] = useState<7 | 30>(7)
  const report = useQuery({ queryKey: ["attention_report", windowDays], queryFn: () => fetchAttentionReport(windowDays) })
  usePageTitle(t("title"))

  return (
    <Page.Root aria-label={t("title")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <Text className="font-medium uppercase" variant="caption" tone="muted">
              {t("eyebrow")}
            </Text>
            <PageHeading>{t("title")}</PageHeading>
            <Page.Description>{t("description")}</Page.Description>
          </div>
          <div aria-label={t("window_label")} className="inline-flex overflow-hidden rounded border border-border bg-surface text-sm">
            {WINDOWS.map((days) => (
              <button
                aria-pressed={windowDays === days}
                className={`px-3 py-1.5 font-medium ${windowDays === days ? "bg-text-primary text-surface" : "text-text-secondary hover:bg-surface-subtle"}`}
                key={days}
                onClick={() => setWindowDays(days)}
                type="button"
              >
                {t("window_days", { count: days })}
              </button>
            ))}
          </div>
        </div>
      </Page.Header>
      {report.isPending ? <Notice>{t("common:loading")}</Notice> : null}
      {report.isError ? <Notice tone="danger">{t("load_error")}</Notice> : null}
      {report.data ? <ReportBody payload={report.data} prefix={prefix} /> : null}
    </Page.Root>
  )
}

function ReportBody({ payload, prefix }: { payload: Awaited<ReturnType<typeof fetchAttentionReport>>; prefix: string }) {
  const { t } = useT("attention_report")
  const empty =
    Object.values(payload.attention.deciding.figures).every((item) => item.count === 0) &&
    Object.values(payload.attention.judging.figures).every((item) => (item.count ?? item.value_ms) === 0) &&
    Object.values(payload.attention.wasted.rules).every((item) => item.count === 0)
  return (
    <>
      <Notice tone="warning">
        <strong>{t("estimate_label")}</strong> {t("estimate_note")}
      </Notice>
      {empty ? <Notice>{t("empty")}</Notice> : null}
      <div className="grid gap-4 lg:grid-cols-3">
        <Bucket title={t("bucket_deciding")} figures={payload.attention.deciding.figures} rules={DECIDING_RULES} />
        <Bucket title={t("bucket_judging")} figures={payload.attention.judging.figures} rules={JUDGING_RULES} />
        <Bucket title={t("bucket_wasted")} figures={payload.attention.wasted.rules} rules={WASTED_RULES} jobLinks prefix={prefix} />
      </div>
      <PageTime pageTime={payload.page_time} prefix={prefix} />
      <Section.Root className="border-dashed bg-surface-subtle">
        <SectionHeading>{t("not_attention")}</SectionHeading>
        <Text className="mt-1" tone="muted">
          {t("not_attention_note")}
        </Text>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <Metric
            label={t("agent_runtime")}
            value={formatDuration(payload.machine_time.agent_runtime.value_ms)}
            detail={t("samples", { count: payload.machine_time.agent_runtime.sample_count })}
          />
          <Metric
            label={t("queue_wait")}
            value={formatDuration(payload.machine_time.queue_wait.value_ms)}
            detail={t("samples", { count: payload.machine_time.queue_wait.sample_count })}
          />
        </div>
      </Section.Root>
      <Text variant="caption" tone="muted">
        {t("scope_note")}
      </Text>
    </>
  )
}

function Bucket({
  title,
  figures,
  rules,
  jobLinks = false,
  prefix = ""
}: {
  title: string
  figures: Record<string, AttentionFigure>
  rules: string[]
  jobLinks?: boolean
  prefix?: string
}) {
  const { t } = useT("attention_report")
  return (
    <Section.Root>
      <SectionHeading>{title}</SectionHeading>
      <div className="mt-4 space-y-3">
        {rules.map((rule) => {
          const figure = figures[rule]
          if (!figure) return null
          const value = figure.value_ms == null ? (figure.count ?? 0) : formatDuration(figure.value_ms)
          return (
            <div className="border-t border-border pt-3 first:border-0 first:pt-0" key={rule}>
              <div className="flex items-baseline justify-between gap-3">
                <Text>{t(`rule_${rule}`)}</Text>
                <strong className="text-lg text-text-primary">{value}</strong>
              </div>
              {jobLinks && figure.job_ids?.length ? (
                <div className="mt-1 flex flex-wrap gap-2">
                  {figure.job_ids.map((id) => (
                    <Link className="text-xs text-brand hover:underline" key={id} to={withRoutePrefix(`/jobs/${id}`, prefix)}>
                      {t("job_link", { id })}
                    </Link>
                  ))}
                </div>
              ) : null}
            </div>
          )
        })}
      </div>
    </Section.Root>
  )
}

function PageTime({ pageTime, prefix }: { pageTime: Awaited<ReturnType<typeof fetchAttentionReport>>["page_time"]; prefix: string }) {
  const { t } = useT("attention_report")
  if (pageTime.telemetry_state === "off")
    return (
      <Section.Root>
        <SectionHeading>{t("page_time")}</SectionHeading>
        <Notice className="mt-3" tone="warning">
          {t("collection_off")}{" "}
          <Link className="font-medium underline" to={withRoutePrefix("/settings/edit", prefix)}>
            {t("enable_collection")}
          </Link>
        </Notice>
      </Section.Root>
    )
  const entries = Object.entries(pageTime.by_page_type)
  return (
    <Section.Root>
      <SectionHeading>{t("page_time")}</SectionHeading>
      <Text className="mt-1" tone="muted">
        {t("page_time_note")}
      </Text>
      {entries.length === 0 ? (
        <Notice className="mt-3">{t("no_page_samples")}</Notice>
      ) : (
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          {entries.map(([pageType, statistic]) => (
            <PageStatistic key={pageType} pageType={pageType} statistic={statistic} />
          ))}
        </div>
      )}
    </Section.Root>
  )
}

function PageStatistic({ pageType, statistic }: { pageType: string; statistic: AttentionPageStatistic }) {
  const { t } = useT("attention_report")
  return (
    <article className="rounded border border-border bg-surface-subtle p-3">
      <Text className="font-medium">{t(`page_${pageType.replaceAll(".", "_")}`, { defaultValue: pageType })}</Text>
      <div className="mt-2 grid grid-cols-2 gap-3">
        <Metric
          label="p50"
          value={statistic.p50_active_ms.status === "available" ? formatDuration(statistic.p50_active_ms.value_ms) : t("not_enough_data")}
          detail={t("samples", { count: statistic.p50_active_ms.sample_count })}
        />
        <Metric
          label="p90"
          value={statistic.p90_active_ms.status === "available" ? formatDuration(statistic.p90_active_ms.value_ms) : t("not_enough_data")}
          detail={t("samples", { count: statistic.p90_active_ms.sample_count })}
        />
      </div>
    </article>
  )
}

function Metric({ label, value, detail }: { label: string; value: string; detail: string }) {
  return (
    <div>
      <Text variant="caption" tone="muted">
        {label}
      </Text>
      <Text className="font-semibold">{value}</Text>
      <Text variant="caption" tone="muted">
        {detail}
      </Text>
    </div>
  )
}
function formatDuration(value?: number) {
  if (value == null) return "—"
  if (value < 60_000) return `${Math.round(value / 1000)}s`
  if (value < 3_600_000) return `${Math.round(value / 60_000)}m`
  return `${Math.round(value / 360_000) / 10}h`
}
