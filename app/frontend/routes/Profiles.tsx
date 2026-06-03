import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { fetchProfile, fetchProfiles, type TeamProfileActivity, type TeamProfileCounts, type TeamProfileDetail, type TeamProfileEpic, type TeamProfileJob, type TeamProfileRepository, type TeamProfileSummary } from "../api/profiles"
import { StatusPill } from "../components/StatusPill"

export function TeamDirectoryRoute() {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const profiles = useQuery({
    queryKey: ["profiles"],
    queryFn: fetchProfiles
  })

  return (
    <main aria-label="Team directory" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900">Team directory</h1>
      </header>

      {profiles.isPending ? <PanelMessage>Loading profiles...</PanelMessage> : null}
      {profiles.isError ? <ProfilesError error={profiles.error} /> : null}
      {profiles.isSuccess && profiles.data.team_user_count <= 1 ? <PanelMessage>Only one user exists on this Syrus instance.</PanelMessage> : null}
      {profiles.isSuccess && profiles.data.team_user_count > 1 ? (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {profiles.data.profiles.map((profile) => <ProfileCard key={profile.id} prefix={prefix} profile={profile} />)}
        </div>
      ) : null}
    </main>
  )
}

export function TeamProfileRoute() {
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
        <Link className="text-sm text-blue-600 underline hover:no-underline" to={`${prefix}/profiles`}>Team directory</Link>
      </header>

      {profile.isPending ? <PanelMessage>Loading profile...</PanelMessage> : null}
      {profile.isError ? <ProfilesError error={profile.error} /> : null}
      {profile.isSuccess ? <ProfileDetail prefix={prefix} profile={profile.data.profile} /> : null}
    </main>
  )
}

function ProfileCard({ profile, prefix }: { profile: TeamProfileSummary; prefix: string }) {
  return (
    <article className="rounded border border-gray-200 bg-white p-4">
      <div className="flex items-start gap-3">
        <Avatar avatarUrl={profile.avatar_url} displayName={profile.display_name} />
        <div className="min-w-0 flex-1">
          <Link className="text-base font-semibold text-blue-600 hover:underline" to={withRoutePrefix(profile.profile_path, prefix)}>{profile.display_name}</Link>
          {profile.github_handle ? <div className="text-sm text-gray-500">@{profile.github_handle}</div> : null}
          {profile.bio_excerpt ? <p className="mt-2 line-clamp-2 text-sm text-gray-600">{profile.bio_excerpt}</p> : null}
        </div>
      </div>
      <Counts counts={profile.counts} />
    </article>
  )
}

function ProfileDetail({ profile, prefix }: { profile: TeamProfileDetail; prefix: string }) {
  return (
    <>
      <section className="rounded border border-gray-200 bg-white p-5">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
          <Avatar avatarUrl={profile.avatar_url} displayName={profile.display_name} size="large" />
          <div className="min-w-0 flex-1">
            <h1 className="text-2xl font-semibold text-gray-900">
              <Link className="text-blue-600 hover:underline" to={withRoutePrefix(profile.profile_path, prefix)}>{profile.display_name}</Link>
            </h1>
            {profile.github_handle ? <a className="mt-1 inline-block text-sm text-blue-600 hover:underline" href={`https://github.com/${profile.github_handle}`} rel="noopener noreferrer" target="_blank">@{profile.github_handle}</a> : null}
            {profile.profile_bio ? <p className="mt-3 max-w-3xl whitespace-pre-wrap text-sm leading-6 text-gray-700">{profile.profile_bio}</p> : null}
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
  return (
    <div className="rounded border border-gray-200 px-2 py-2">
      <dt className="text-gray-500">{label}</dt>
      <dd className="mt-0.5 font-semibold text-gray-900">{value}</dd>
    </div>
  )
}

function SummaryList<T>({ title, empty, items, renderItem }: { title: string; empty: string; items: T[]; prefix: string; renderItem: (item: T) => ReactNode }) {
  return (
    <section className="rounded border border-gray-200 bg-white">
      <h2 className="border-b border-gray-200 px-4 py-3 text-sm font-semibold text-gray-900">{title}</h2>
      {items.length === 0 ? <p className="p-4 text-sm text-gray-500">{empty}</p> : (
        <div className="divide-y divide-gray-100">
          {items.map((item, index) => <div className="px-4 py-3" key={index}>{renderItem(item)}</div>)}
        </div>
      )}
    </section>
  )
}

function EpicRow({ epic, prefix }: { epic: TeamProfileEpic; prefix: string }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(epic.path, prefix)}>{epic.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500">{epic.display_number} · {epic.repository.slug}</div>
      </div>
      <StatusPill state={epic.state} />
    </div>
  )
}

function JobRow({ job, prefix }: { job: TeamProfileJob; prefix: string }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(job.path, prefix)}>{job.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500">{job.repository.slug}</div>
      </div>
      <StatusPill state={job.state} />
    </div>
  )
}

function RepositoryRow({ repository, prefix }: { repository: TeamProfileRepository; prefix: string }) {
  return <Link className="font-mono text-sm text-blue-600 hover:underline" to={withRoutePrefix(repository.path, prefix)}>{repository.slug}</Link>
}

function ActivityRow({ activity, prefix }: { activity: TeamProfileActivity; prefix: string }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(activity.path, prefix)}>{activity.title}</Link>
        <div className="mt-1 text-xs text-gray-500">{activity.type} · {activity.repository_slug} · {formatDate(activity.occurred_at)}</div>
      </div>
      <StatusPill state={activity.state} />
    </div>
  )
}

function Avatar({ avatarUrl, displayName, size = "normal" }: { avatarUrl: string | null; displayName: string; size?: "normal" | "large" }) {
  const dimension = size === "large" ? "h-20 w-20 text-2xl" : "h-12 w-12 text-base"
  const initials = displayName.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "U"

  if (avatarUrl) {
    return <img alt="" className={`${dimension} shrink-0 rounded-full object-cover ring-1 ring-gray-200`} src={avatarUrl} />
  }

  return <div aria-hidden="true" className={`${dimension} flex shrink-0 items-center justify-center rounded-full bg-gray-100 font-semibold text-gray-500 ring-1 ring-gray-200`}>{initials}</div>
}

function PanelMessage({ children }: { children: ReactNode }) {
  return <div className="rounded border border-gray-200 bg-white p-4 text-sm text-gray-600">{children}</div>
}

function ProfilesError({ error }: { error: Error }) {
  const message = error instanceof ApiError ? error.message : "Unable to load profiles."
  return <div className="rounded border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">{message}</div>
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path}`
}

function formatDate(value: string | null) {
  if (!value) return "not started"
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(new Date(value))
}
