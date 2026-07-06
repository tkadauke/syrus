import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { fetchProfile, fetchProfiles, type TeamProfileActivity, type TeamProfileCounts, type TeamProfileDetail, type TeamProfileEpic, type TeamProfileJob, type TeamProfileRepository, type TeamProfileSummary } from "../api/profiles"
import { StatusPill } from "../components/StatusPill"
import { useT } from "../hooks/useT"

export function TeamDirectoryRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const profiles = useQuery({
    queryKey: ["profiles"],
    queryFn: fetchProfiles
  })

  return (
    <main aria-label="Team directory" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{/* TODO: missing i18n key */}Team directory</h1>
      </header>

      {profiles.isPending ? <PanelMessage>{/* TODO: missing i18n key */}Loading profiles...</PanelMessage> : null}
      {profiles.isError ? <ProfilesError error={profiles.error} /> : null}
      {profiles.isSuccess && profiles.data.team_user_count <= 1 ? <PanelMessage>{/* TODO: missing i18n key */}Only one user exists on this Syrus instance.</PanelMessage> : null}
      {profiles.isSuccess && profiles.data.team_user_count > 1 ? (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {profiles.data.profiles.map((profile) => <ProfileCard key={profile.id} prefix={prefix} profile={profile} />)}
        </div>
      ) : null}
    </main>
  )
}

export function TeamProfileRoute() {
  const { t } = useT("settings")
  const { id } = useParams()
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const profile = useQuery({
    queryKey: ["profiles", id],
    queryFn: () => fetchProfile(id || ""),
    enabled: Boolean(id)
  })

  return (
    <main aria-label="Team profile" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <Link className="text-sm text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${prefix}/profiles`}>{/* TODO: missing i18n key */}Team directory</Link>
      </header>

      {profile.isPending ? <PanelMessage>{/* TODO: missing i18n key */}Loading profile...</PanelMessage> : null}
      {profile.isError ? <ProfilesError error={profile.error} /> : null}
      {profile.isSuccess ? <ProfileDetail prefix={prefix} profile={profile.data.profile} /> : null}
    </main>
  )
}

function ProfileCard({ profile, prefix }: { profile: TeamProfileSummary; prefix: string }) {
  const { t } = useT("settings")
  return (
    <article className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div className="flex items-start gap-3">
        <Avatar avatarUrl={profile.avatar_url} displayName={profile.display_name} />
        <div className="min-w-0 flex-1">
          <Link className="text-base font-semibold text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(profile.profile_path, prefix)}>{profile.display_name}</Link>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-gray-500 dark:text-gray-400">
            <span>{profile.role_label}</span>
            {profile.github_handle ? <span>@{profile.github_handle}</span> : null}
          </div>
          {profile.bio_excerpt ? <p className="mt-2 line-clamp-2 text-sm text-gray-600 dark:text-gray-400">{profile.bio_excerpt}</p> : null}
        </div>
      </div>
      <Counts counts={profile.counts} />
    </article>
  )
}

function ProfileDetail({ profile, prefix }: { profile: TeamProfileDetail; prefix: string }) {
  const { t } = useT("settings")
  return (
    <>
      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
          <Avatar avatarUrl={profile.avatar_url} displayName={profile.display_name} size="large" />
          <div className="min-w-0 flex-1">
            <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">
              <Link className="text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(profile.profile_path, prefix)}>{profile.display_name}</Link>
            </h1>
            {profile.github_handle ? <a className="mt-1 inline-block text-sm text-blue-600 dark:text-blue-400 hover:underline" href={`https://github.com/${profile.github_handle}`} rel="noopener noreferrer" target="_blank">@{profile.github_handle}</a> : null}
            {profile.profile_bio ? <p className="mt-3 max-w-3xl whitespace-pre-wrap text-sm leading-6 text-gray-700 dark:text-gray-300">{profile.profile_bio}</p> : null}
            <Counts counts={profile.counts} />
          </div>
        </div>
      </section>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <SummaryList title="Owned epics" empty="No active epics." items={profile.epics} prefix={prefix} renderItem={(epic) => <EpicRow epic={epic} prefix={prefix} />} />
        <SummaryList title="Owned jobs" empty="No jobs." items={profile.jobs} prefix={prefix} renderItem={(job) => <JobRow job={job} prefix={prefix} />} />
        <SummaryList title="Repositories" empty="No active repositories." items={profile.repositories} prefix={prefix} renderItem={(repository) => <RepositoryRow prefix={prefix} repository={repository} />} />
        <SummaryList title="Recent activity" empty="No activity yet." items={profile.recent_activity} prefix={prefix} renderItem={(activity) => <ActivityRow activity={activity} prefix={prefix} />} />
      </div>
    </>
  )
}

function Counts({ counts }: { counts: TeamProfileCounts }) {
  const { t } = useT("settings")
  return (
    <dl className="mt-4 grid grid-cols-4 gap-2 text-center text-xs">
      <Count label="Repos" value={counts.repositories} />
      <Count label="Epics" value={counts.epics} />
      <Count label="Jobs" value={counts.jobs} />
      <Count label="Open" value={counts.open_jobs} />
    </dl>
  )
}

function Count({ label, value }: { label: string; value: number }) {
  const { t } = useT("settings")
  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 px-2 py-2">
      <dt className="text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="mt-0.5 font-semibold text-gray-900 dark:text-gray-100">{value}</dd>
    </div>
  )
}

function SummaryList<T>({ title, empty, items, renderItem }: { title: string; empty: string; items: T[]; prefix: string; renderItem: (item: T) => ReactNode }) {
  const { t } = useT("settings")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <h2 className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h2>
      {items.length === 0 ? <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{empty}</p> : (
        <div className="divide-y divide-gray-100 dark:divide-gray-800">
          {items.map((item, index) => <div className="px-4 py-3" key={index}>{renderItem(item)}</div>)}
        </div>
      )}
    </section>
  )
}

function EpicRow({ epic, prefix }: { epic: TeamProfileEpic; prefix: string }) {
  const { t } = useT("settings")
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(epic.path, prefix)}>{epic.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{epic.display_number} · {epic.repository.slug}</div>
      </div>
      <StatusPill state={epic.state} />
    </div>
  )
}

function JobRow({ job, prefix }: { job: TeamProfileJob; prefix: string }) {
  const { t } = useT("settings")
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(job.path, prefix)}>{job.title}</Link>
        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          {job.owner ? <OwnerProfileLink owner={job.owner} prefix={prefix} /> : null}
          <span>{job.repository.slug} · updated {formatDate(job.updated_at)}</span>
        </div>
      </div>
      <StatusPill state={job.state} />
    </div>
  )
}

function OwnerProfileLink({ owner, prefix }: { owner: NonNullable<TeamProfileJob["owner"]>; prefix: string }) {
  const { t } = useT("settings")
  return (
    <Link className="rounded bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 font-medium text-gray-600 dark:text-gray-400 hover:text-blue-700 dark:hover:text-blue-300 hover:underline" to={withRoutePrefix(owner.profile_path, prefix)}>
      {owner.display_name}
    </Link>
  )
}

function RepositoryRow({ repository, prefix }: { repository: TeamProfileRepository; prefix: string }) {
  const { t } = useT("settings")
  return <Link className="font-mono text-sm text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(repository.path, prefix)}>{repository.slug}</Link>
}

function ActivityRow({ activity, prefix }: { activity: TeamProfileActivity; prefix: string }) {
  const { t } = useT("settings")
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 dark:text-blue-400 hover:underline" to={withRoutePrefix(activity.path, prefix)}>{activity.title}</Link>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{activity.type} · {activity.repository_slug} · {formatDate(activity.occurred_at)}</div>
      </div>
      <StatusPill state={activity.state} />
    </div>
  )
}

function Avatar({ avatarUrl, displayName, size = "normal" }: { avatarUrl: string | null; displayName: string; size?: "normal" | "large" }) {
  const { t } = useT("settings")
  const dimension = size === "large" ? "h-20 w-20 text-2xl" : "h-12 w-12 text-base"
  const initials = displayName.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "U"

  if (avatarUrl) {
    return <img alt="" className={`${dimension} shrink-0 rounded-full object-cover ring-1 ring-gray-200 dark:ring-gray-700`} src={avatarUrl} />
  }

  return <div aria-hidden="true" className={`${dimension} flex shrink-0 items-center justify-center rounded-full bg-gray-100 dark:bg-gray-800 font-semibold text-gray-500 dark:text-gray-400 ring-1 ring-gray-200 dark:ring-gray-700`}>{initials}</div>
}

function PanelMessage({ children }: { children: ReactNode }) {
  const { t } = useT("settings")
  return <div className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm text-gray-600 dark:text-gray-400">{children}</div>
}

function ProfilesError({ error }: { error: Error }) {
  const { t } = useT("settings")
  const message = error instanceof ApiError ? error.message : "Unable to load profiles."
  return <div className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 p-4 text-sm text-red-700 dark:text-red-300" role="alert">{message}</div>
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path}`
}

function formatDate(value: string | null) {
  if (!value) return "not started"
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(new Date(value))
}
