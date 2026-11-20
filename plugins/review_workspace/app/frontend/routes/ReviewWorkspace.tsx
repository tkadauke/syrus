import { Notice, Page, PageHeading, Section, SectionHeading, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useQuery } from "@tanstack/react-query"
import { Link, Navigate, useLocation, useParams } from "react-router-dom"
import { fetchReviewWorkspace, type ReviewWorkspaceJob } from "../api/reviewWorkspace"

export default function ReviewWorkspaceRoute() {
  const { t } = useT("review_workspace")
  const location = useLocation()
  const { job_id: requestedJobId } = useParams()
  const prefix = routePrefix(location.pathname)
  const review = useQuery({ queryKey: ["review_workspace"], queryFn: fetchReviewWorkspace })
  usePageTitle(t("title"))

  if (review.isPending)
    return (
      <Page.Root size="wide">
        <Notice>{t("common:loading")}</Notice>
      </Page.Root>
    )
  if (review.isError)
    return (
      <Page.Root size="wide">
        <Notice tone="danger">{t("load_error")}</Notice>
      </Page.Root>
    )

  const jobs = review.data?.jobs ?? []
  if (jobs.length === 0) return <EmptyWorkspace />

  const active = jobs.find((job) => job.slug === requestedJobId || String(job.id) === requestedJobId) ?? jobs[0]
  const canonicalPath = withRoutePrefix(`/review/${active.slug}`, prefix)
  if (location.pathname !== canonicalPath) return <Navigate replace to={canonicalPath} />

  return (
    <Page.Root aria-label={t("title")} className="space-y-5" gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <PageHeading>{t("title")}</PageHeading>
        <Page.Description>{t("position", { current: jobs.indexOf(active) + 1, count: jobs.length })}</Page.Description>
      </Page.Header>
      <div className="grid gap-4 lg:grid-cols-[minmax(15rem,20rem)_minmax(0,1fr)]">
        <Section.Root aria-label={t("ready_now")}>
          <SectionHeading>{t("ready_now")}</SectionHeading>
          <div className="mt-3 space-y-2">
            {jobs.map((job) => (
              <JobLink active={job.id === active.id} job={job} key={job.id} prefix={prefix} />
            ))}
          </div>
        </Section.Root>
        <Section.Root>
          <Text variant="caption" tone="muted">
            {active.slug} · {active.repository.slug}
          </Text>
          <PageHeading className="mt-2">{active.title}</PageHeading>
          <div className="mt-4 flex flex-wrap gap-2 text-xs text-text-secondary">
            <span className="rounded border border-border px-2 py-1">{t("priority", { priority: active.priority })}</span>
            {active.dependency_blocked ? (
              <span className="rounded border border-warning-border px-2 py-1 text-warning-text">{t("dependency_blocked")}</span>
            ) : null}
          </div>
          <Text className="mt-5" tone="muted">
            {t("action_hint")}
          </Text>
          <Link
            className="mt-4 inline-flex rounded bg-brand px-4 py-2 text-sm font-semibold text-on-brand hover:opacity-90"
            to={withRoutePrefix(`/jobs/${active.slug}?tab=review`, prefix)}
          >
            {t("open_review")}
          </Link>
        </Section.Root>
      </div>
    </Page.Root>
  )
}

function JobLink({ active, job, prefix }: { active: boolean; job: ReviewWorkspaceJob; prefix: string }) {
  const { t } = useT("review_workspace")
  return (
    <Link
      aria-current={active ? "page" : undefined}
      className={`block rounded border p-3 ${active ? "border-brand bg-brand-subtle" : "border-border hover:bg-surface-subtle"}`}
      to={withRoutePrefix(`/review/${job.slug}`, prefix)}
    >
      <div className="flex items-center justify-between gap-2 text-xs text-text-secondary">
        <span>{job.slug}</span>
        <span>{t("ready")}</span>
      </div>
      <Text className="mt-1 font-medium">{job.title}</Text>
    </Link>
  )
}

function EmptyWorkspace() {
  const { t } = useT("review_workspace")
  return (
    <Page.Root size="narrow">
      <Page.Header>
        <PageHeading>{t("all_caught_up")}</PageHeading>
        <Page.Description>{t("empty")}</Page.Description>
      </Page.Header>
    </Page.Root>
  )
}
