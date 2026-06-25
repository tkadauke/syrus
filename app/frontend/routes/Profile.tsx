import { useQuery } from "@tanstack/react-query"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { fetchProfile, type TeamProfileJob } from "../api/profiles"

export { AccountProfileRoute } from "./AccountSettings"

export function ProfileRoute() {
  const { id } = useParams()
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const profile = useQuery({
    queryKey: ["profile", id],
    queryFn: () => fetchProfile(id || "")
  })

  if (profile.isPending) {
    return <main aria-label="User profile" className="mx-auto max-w-5xl p-6 text-sm text-gray-600 dark:text-gray-400">Loading profile...</main>
  }

  if (profile.isError) {
    const message = profile.error instanceof ApiError ? profile.error.message : "Unable to load this profile."
    return (
      <main aria-label="User profile" className="mx-auto max-w-5xl p-6">
        <p className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 px-3 py-2 text-sm text-red-700 dark:text-red-300">{message}</p>
      </main>
    )
  }

  const user = profile.data.profile

  return (
    <main aria-label="User profile" className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-5">
        <div className="min-w-0">
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{user.role_label}</p>
          <h1 className="mt-1 break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">{user.display_name}</h1>
          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-600 dark:text-gray-400">
            {user.github_handle ? <span>@{user.github_handle}</span> : <span>No GitHub handle set</span>}
          </div>
        </div>
        <p className="mt-4 max-w-3xl text-sm leading-6 text-gray-700 dark:text-gray-300">{user.profile_bio || "No bio listed."}</p>
      </header>

      <section aria-label="Profile details" className="grid gap-3 sm:grid-cols-3">
        <ProfileDetail label="Company" value={user.profile_company} empty="No company listed" />
        <ProfileDetail label="Location" value={user.profile_location} empty="No location listed" />
        <ProfileWebsite value={user.profile_website} />
      </section>

      <section aria-label="Work summary" className="grid gap-3 sm:grid-cols-4">
        <SummaryStat label="Repositories" value={user.counts.repositories} />
        <SummaryStat label="Epics" value={user.counts.epics} />
        <SummaryStat label="Open jobs" value={user.counts.open_jobs} />
        <SummaryStat label="Jobs" value={user.counts.jobs} />
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">Recent work</h2>
        </div>
        {user.jobs.length > 0 ? (
          <div className="divide-y divide-gray-100 dark:divide-gray-800">
            {user.jobs.map((job) => <RecentJob job={job} key={job.id} prefix={prefix} />)}
          </div>
        ) : (
          <div className="px-4 py-6 text-sm text-gray-600 dark:text-gray-400">
            No owned work yet. Jobs, epics, and repository activity will appear here once this user starts delegating work.
          </div>
        )}
      </section>
    </main>
  )
}

function ProfileDetail({ empty, label, value }: { empty: string; label: string; value: string | null }) {
  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</p>
      <p className="mt-1 break-words text-sm text-gray-800 dark:text-gray-200">{value || empty}</p>
    </div>
  )
}

function ProfileWebsite({ value }: { value: string | null }) {
  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Website</p>
      <p className="mt-1 break-words text-sm text-gray-800 dark:text-gray-200">
        {value ? <a className="text-blue-600 dark:text-blue-400 hover:underline" href={value} rel="noopener" target="_blank">{value}</a> : "No website listed"}
      </p>
    </div>
  )
}

function SummaryStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</p>
      <p className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{value}</p>
    </div>
  )
}

function RecentJob({ job, prefix }: { job: TeamProfileJob; prefix: string }) {
  return (
    <article className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
      <div className="min-w-0">
        <Link className="break-words text-sm font-medium text-gray-900 dark:text-gray-100 hover:text-blue-600 dark:hover:text-blue-400 hover:underline" to={withRoutePrefix(job.path, prefix)}>
          {job.title}
        </Link>
        <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
          {job.owner ? <OwnerProfileLink owner={job.owner} prefix={prefix} /> : null}
          <span>{job.repository.slug} · updated {formatDate(job.updated_at)}</span>
        </div>
      </div>
      <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300">{humanize(job.state)}</span>
    </article>
  )
}

function OwnerProfileLink({ owner, prefix }: { owner: NonNullable<TeamProfileJob["owner"]>; prefix: string }) {
  return (
    <Link className="rounded bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 font-medium text-gray-600 dark:text-gray-400 hover:text-blue-700 dark:hover:text-blue-300 hover:underline" to={withRoutePrefix(owner.profile_path, prefix)}>
      {owner.display_name}
    </Link>
  )
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}

function humanize(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}

function formatDate(value: string | null) {
  if (!value) return "unknown"

  return new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}
