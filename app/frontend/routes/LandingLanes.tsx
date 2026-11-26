import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchLandingLanes, type LandingLane, type LandingLanesPayload, type LandingLanesRepository } from "../api/landingLanes"
import { PageHeading } from "../components/Heading"
import { Notice, Page, Section, Surface } from "../components/ui"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { withRoutePrefix } from "../lib/routing"

export function LandingLanesRoute() {
  const { t } = useT("dashboard")
  usePageTitle(t("landing_lanes.title"))
  const query = useQuery({ queryKey: ["landing_lanes"], queryFn: ({ signal }) => fetchLandingLanes({ signal }) })

  return (
    <Page.Root>
      <PageHeading>{t("landing_lanes.title")}</PageHeading>
      {query.isError ? <Notice tone="danger">{t("landing_lanes.load_error")}</Notice> : null}
      {query.isLoading ? <div className="text-sm text-muted">{t("loading")}</div> : null}
      {query.data ? <LandingLanesPage payload={query.data} /> : null}
    </Page.Root>
  )
}

export function LandingLanesPage({ payload }: { payload: LandingLanesPayload }) {
  return (
    <div className="space-y-6">
      {payload.repositories.map((repository) => (
        <RepositoryLanes key={repository.id} repository={repository} />
      ))}
    </div>
  )
}

function RepositoryLanes({ repository }: { repository: LandingLanesRepository }) {
  const { t } = useT("dashboard")
  return (
    <Section.Root>
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-lg font-semibold text-default">{repository.slug}</h2>
        <div className="text-sm text-muted">
          {t("landing_lanes.repository_summary", {
            busy: repository.busy_lane_count,
            total: repository.landing_concurrency,
            waiting: repository.approved_backlog.length
          })}
        </div>
      </div>
      <div className="space-y-3">
        {repository.lanes.map((lane) => (
          <LaneCard key={lane.number} lane={lane} />
        ))}
      </div>
      <div className="mt-4">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-muted">{t("landing_lanes.waiting_backlog")}</h3>
        {repository.approved_backlog.length === 0 ? (
          <p className="mt-2 text-sm text-muted">{t("landing_lanes.no_waiting")}</p>
        ) : (
          <ol className="mt-2 flex flex-wrap gap-2">
            {repository.approved_backlog.map((job) => (
              <li key={job.id}>
                <Link className="text-sm font-medium text-link hover:underline" to={job.app_path}>
                  {job.position}. {job.slug}
                </Link>
              </li>
            ))}
          </ol>
        )}
      </div>
    </Section.Root>
  )
}

function LaneCard({ lane }: { lane: LandingLane }) {
  const { t } = useT("dashboard")
  if (lane.empty) {
    return (
      <Surface className="border-dashed px-4 py-4">
        <div className="flex items-center gap-3 text-sm text-muted">
          <span className="font-semibold text-default">{t("landing_lanes.lane", { number: lane.number })}</span>
          <span>{lane.draining ? t("landing_lanes.draining") : t("landing_lanes.empty")}</span>
        </div>
      </Surface>
    )
  }

  const estimate = bestCaseMinutes(lane.best_case_remaining_seconds)
  return (
    <Surface className="px-4 py-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
            <span className="font-semibold text-default">{t("landing_lanes.lane", { number: lane.number })}</span>
            {lane.anchor_job ? <JobLink job={lane.anchor_job} /> : null}
            {lane.workflow ? (
              <Link className="text-link hover:underline" to={lane.workflow.app_path}>
                {lane.workflow.slug}
              </Link>
            ) : null}
          </div>
          {lane.member_jobs && lane.member_jobs.length > 0 ? (
            <div className="mt-1 flex flex-wrap gap-2 text-xs text-muted">
              <span>{t("landing_lanes.bundle_members")}</span>
              {lane.member_jobs.map((job) => <JobLink job={job} key={job.id} />)}
            </div>
          ) : null}
        </div>
        <div className="text-right text-sm">
          <div className="font-medium text-default">{phaseLabel(lane, t)}</div>
          <div className="text-muted">{t("landing_lanes.best_case", { minutes: estimate })}</div>
        </div>
      </div>
      {lane.multisect?.sub_lanes.length ? (
        <div className="mt-3 space-y-2">
          {lane.multisect.sub_lanes.map((subLane) => (
            <div className="grid grid-cols-[minmax(7rem,auto)_1fr] items-center gap-3" key={subLane.step_id}>
              <span className="text-xs text-muted">{t("landing_lanes.multisect_rung", { role: subLane.role, round: subLane.round })}</span>
              <ProgressBar progress={subLane.state === "succeeded" ? 1 : 0.35} />
            </div>
          ))}
        </div>
      ) : <div className="mt-3"><LaneProgress lane={lane} /></div>}
      {lane.repair_round ? (
        <div className="mt-3 text-xs text-muted">
          <span className="font-semibold text-default">{t("landing_lanes.repair_round", { round: lane.repair_round })}</span>
          {lane.graders?.length ? (
            <span className="ml-2">
              {lane.graders.map((grader) => grader.carried ? t("landing_lanes.carried_grader", { name: grader.name }) : grader.name).join(" · ")}
            </span>
          ) : null}
        </div>
      ) : null}
    </Surface>
  )
}

function JobLink({ job }: { job: { id: number; slug: string; app_path: string } }) {
  return <Link className="font-medium text-link hover:underline" to={job.app_path}>{job.slug}</Link>
}

function ProgressBar({ progress }: { progress: number }) {
  const { t } = useT("dashboard")
  const width = `${Math.max(0, Math.min(progress, 1)) * 100}%`
  return <div aria-label={t("landing_lanes.progress")} className="h-1.5 overflow-hidden rounded-full bg-subtle"><div className="h-full rounded-full bg-brand" style={{ width }} /></div>
}

const PHASES = ["assemble", "build", "prepare", "reconcile", "grade", "collect", "land"]

function LaneProgress({ lane }: { lane: LandingLane }) {
  const { t } = useT("dashboard")
  const currentIndex = Math.max(0, PHASES.indexOf(lane.phase ?? "assemble"))
  const gradeWeight = Math.max(2, (lane.graders ?? []).reduce((sum, grader) => sum + grader.expected_seconds, 0) / 30)
  const gradeProgress = weightedGraderProgress(lane)

  return (
    <div aria-label={t("landing_lanes.progress")} className="flex h-1.5 gap-0.5 overflow-hidden rounded-full">
      {lane.rebasing ? <ProgressSegment progress={lane.phase === "reconcile" ? 0.5 : 1} weight={0.6} /> : null}
      {PHASES.map((phase, index) => (
        <ProgressSegment
          key={phase}
          progress={index < currentIndex ? 1 : index > currentIndex ? 0 : phase === "grade" ? gradeProgress : 0.5}
          weight={phase === "grade" ? gradeWeight : 1}
        />
      ))}
    </div>
  )
}

function ProgressSegment({ progress, weight }: { progress: number; weight: number }) {
  return <div className="relative h-full bg-subtle" style={{ flex: weight }}><div className="absolute inset-y-0 left-0 bg-brand" style={{ width: `${progress * 100}%` }} /></div>
}

function weightedGraderProgress(lane: LandingLane) {
  const graders = (lane.graders ?? []).filter((grader) => !grader.carried)
  const total = graders.reduce((sum, grader) => sum + grader.expected_seconds, 0)
  if (total === 0) return lane.progress ?? 0
  return graders.reduce((sum, grader) => sum + grader.expected_seconds * grader.progress, 0) / total
}

function bestCaseMinutes(seconds = 0) {
  return Math.max(1, Math.ceil(seconds / 60))
}

function phaseLabel(lane: LandingLane, t: (key: string, options?: Record<string, unknown>) => string) {
  if (lane.rebasing) return t("landing_lanes.rebasing")
  return t(`landing_lanes.phases.${lane.phase ?? "assemble"}`)
}

export function LandingLanesStrip({ prefix = "" }: { prefix?: string }) {
  const { t } = useT("dashboard")
  const query = useQuery({ queryKey: ["landing_lanes"], queryFn: ({ signal }) => fetchLandingLanes({ signal }) })
  if (!query.data) return null

  return (
    <Surface className="px-3 py-3">
      <div className="mb-2 flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-default">{t("landing_lanes.title")}</h2>
        <Link className="text-xs font-semibold text-link hover:underline" to={withRoutePrefix("/landing_lanes", prefix)}>{t("landing_lanes.view_all")}</Link>
      </div>
      <div className="space-y-3">
        {query.data.repositories.map((repository) => (
          <div key={repository.id}>
            <div className="mb-1 text-xs font-semibold text-muted">{repository.slug}</div>
            <div className="space-y-1">
              {repository.lanes.map((lane) => (
                <div className="grid grid-cols-[4rem_minmax(6rem,1fr)_minmax(5rem,auto)_minmax(5rem,1fr)_auto] items-center gap-2 text-xs" key={lane.number}>
                  <span>{t("landing_lanes.lane", { number: lane.number })}</span>
                  <span className="truncate font-medium">{lane.empty ? t("landing_lanes.empty") : lane.anchor_job?.slug}</span>
                  <span className="truncate text-muted">{lane.empty ? "" : phaseLabel(lane, t)}</span>
                  <LaneProgress lane={lane} />
                  <span className="whitespace-nowrap text-muted">{lane.empty ? "" : t("landing_lanes.best_case", { minutes: bestCaseMinutes(lane.best_case_remaining_seconds) })}</span>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </Surface>
  )
}
