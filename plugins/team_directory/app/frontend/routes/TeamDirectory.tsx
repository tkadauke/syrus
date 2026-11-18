import { withRoutePrefix } from "@app/lib/routing"
import { Avatar } from "@app/components/Avatar"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { useQuery } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "@app/api/client"
import {
  fetchProfile,
  fetchProfiles,
  type TeamProfileActivity,
  type TeamProfileCounts,
  type TeamProfileDetail,
  type TeamProfileRepository,
  type TeamProfileSummary
} from "../api/profiles"
import { useT } from "@app/hooks/useT"
import { Button, Input, LinkText, Metric, Page, PanelMessage, Pill, Section, StatusPill, Text, buttonClasses } from "@app/components/ui"

export function TeamDirectoryRoute() {
  const { t } = useT("team_directory")
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const params = new URLSearchParams(location.search)
  const searching = Boolean(params.get("q")?.trim())
  const [search, setSearch] = useState(params.get("q") || "")
  const profiles = useQuery({
    queryKey: ["profiles", location.search],
    queryFn: () => fetchProfiles(location.search)
  })

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const next = new URLSearchParams(location.search)
    if (search.trim()) next.set("q", search.trim())
    else next.delete("q")
    next.delete("page")
    navigate({ pathname: location.pathname, search: next.toString() ? `?${next}` : "" })
  }

  function goToPage(page: number) {
    const next = new URLSearchParams(location.search)
    next.set("page", String(page))
    navigate({ pathname: location.pathname, search: `?${next}` })
  }

  return (
    <Page.Root aria-label={t("profiles.aria_directory")} gutter="responsive" size="wide">
      <Page.Header>
        <Page.Title>{t("profiles.team_directory")}</Page.Title>
      </Page.Header>

      <form className="flex max-w-xl items-end gap-2" onSubmit={submitSearch}>
        <label className="min-w-0 flex-1 text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("profiles.search_label")}
          <Input onChange={(event) => setSearch(event.target.value)} placeholder={t("profiles.search_placeholder")} value={search} />
        </label>
        <Button type="submit">{t("profiles.search")}</Button>
      </form>

      {profiles.isPending ? <PanelMessage>{t("profiles.loading")}</PanelMessage> : null}
      {profiles.isError ? <ProfilesError error={profiles.error} /> : null}
      {profiles.isSuccess && !searching && profiles.data.team_user_count <= 1 ? <PanelMessage>{t("profiles.single_user")}</PanelMessage> : null}
      {profiles.isSuccess && (searching || profiles.data.team_user_count > 1) ? (
        <>
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            {profiles.data.profiles.map((profile) => (
              <ProfileCard key={profile.id} prefix={prefix} profile={profile} />
            ))}
          </div>
          {profiles.data.pagination && profiles.data.pagination.total_pages > 1 ? (
            <nav aria-label={t("profiles.pagination")} className="flex items-center justify-between">
              <Button disabled={profiles.data.pagination.page <= 1} onClick={() => goToPage(profiles.data.pagination!.page - 1)} variant="secondary">
                {t("profiles.previous")}
              </Button>
              <span className="text-sm text-gray-600 dark:text-gray-400">
                {t("profiles.page", { page: profiles.data.pagination.page, total: profiles.data.pagination.total_pages })}
              </span>
              <Button
                disabled={profiles.data.pagination.page >= profiles.data.pagination.total_pages}
                onClick={() => goToPage(profiles.data.pagination!.page + 1)}
                variant="secondary"
              >
                {t("profiles.next")}
              </Button>
            </nav>
          ) : null}
        </>
      ) : null}
    </Page.Root>
  )
}

export function TeamProfileRoute() {
  const { t } = useT("team_directory")
  const { id } = useParams()
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const profile = useQuery({
    queryKey: ["profiles", id],
    queryFn: () => fetchProfile(id || ""),
    enabled: Boolean(id)
  })

  return (
    <Page.Root aria-label={t("profiles.aria_profile")} gutter="responsive" size="wide">
      <Page.Header>
        <Link className="text-sm text-brand underline hover:no-underline" to={`${prefix}/profiles`}>
          {t("profiles.team_directory")}
        </Link>
      </Page.Header>

      {profile.isPending ? <PanelMessage>{t("profiles.loading_profile")}</PanelMessage> : null}
      {profile.isError ? <ProfilesError error={profile.error} /> : null}
      {profile.isSuccess ? <ProfileDetail prefix={prefix} profile={profile.data.profile} /> : null}
    </Page.Root>
  )
}

function ProfileCard({ profile, prefix }: { profile: TeamProfileSummary; prefix: string }) {
  const { t } = useT("team_directory")
  return (
    <article className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div className="flex items-start gap-3">
        <Avatar avatarUrl={profile.avatar_url} name={profile.display_name} />
        <div className="min-w-0 flex-1">
          <Link className="text-base font-semibold text-brand hover:underline" to={withRoutePrefix(profile.profile_path, prefix)}>
            {profile.display_name}
          </Link>
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
  const { t } = useT("team_directory")
  const recentActivity: TeamProfileActivity[] = [
    ...profile.jobs.map((job) => ({
      type: "job" as const,
      title: job.title,
      state: job.state,
      repository_slug: job.repository.slug,
      occurred_at: job.updated_at,
      path: job.path
    })),
    ...profile.epics.map((epic) => ({
      type: "epic" as const,
      title: epic.title,
      state: epic.state,
      repository_slug: epic.repository.slug,
      occurred_at: epic.updated_at,
      path: epic.path
    }))
  ]
    .sort((left, right) => (right.occurred_at || "").localeCompare(left.occurred_at || ""))
    .slice(0, 8)
  return (
    <>
      <Section.Root aria-labelledby="profile-name" padding="lg">
        <div className="flex flex-col gap-5 sm:flex-row sm:items-start">
          <Avatar avatarUrl={profile.avatar_url} name={profile.display_name} size="large" />
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <Page.Title id="profile-name">{profile.display_name}</Page.Title>
              <Pill tone="info">{profile.role_label}</Pill>
            </div>
            {profile.github_handle ? (
              <LinkText
                aria-label={t("profiles.github_profile", { handle: profile.github_handle })}
                className="mt-1 inline-block text-sm"
                external
                href={`https://github.com/${profile.github_handle}`}
              >
                @{profile.github_handle}
              </LinkText>
            ) : null}
            {profile.profile_bio ? <Text className="mt-4 max-w-3xl whitespace-pre-wrap leading-6">{profile.profile_bio}</Text> : null}
            <ProfileMetadata profile={profile} />
          </div>
          {profile.is_current_user ? (
            <Link className={buttonClasses("primary", "md", "shrink-0")} to={`${prefix}/profile`}>
              {t("profiles.edit_profile")}
            </Link>
          ) : null}
        </div>
        <Counts counts={profile.counts} prominent />
      </Section.Root>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1.6fr)_minmax(18rem,0.7fr)]">
        <SummaryList
          title={t("profiles.recent_work")}
          empty={t("profiles.empty_work")}
          items={recentActivity}
          prefix={prefix}
          renderItem={(activity) => <ActivityRow activity={activity} prefix={prefix} />}
        />
        <SummaryList
          title={t("profiles.repositories")}
          empty={t("profiles.empty_repositories")}
          items={profile.repositories}
          prefix={prefix}
          renderItem={(repository) => <RepositoryRow prefix={prefix} repository={repository} />}
        />
      </div>
    </>
  )
}

function ProfileMetadata({ profile }: { profile: TeamProfileDetail }) {
  const { t } = useT("team_directory")
  const metadata = [
    profile.profile_company ? { external: false, label: t("profiles.company"), value: profile.profile_company } : null,
    profile.profile_location ? { external: false, label: t("profiles.location"), value: profile.profile_location } : null
  ].filter((item): item is { external: boolean; label: string; value: string } => Boolean(item))

  if (profile.profile_website) {
    metadata.push({ external: true, label: t("profiles.website"), value: profile.profile_website })
  }

  if (metadata.length === 0) return null

  return (
    <dl className="mt-4 flex flex-wrap gap-x-6 gap-y-3 text-sm">
      {metadata.map((item) => (
        <div key={item.label}>
          <dt className="text-xs font-medium uppercase tracking-wide text-text-muted">{item.label}</dt>
          <dd className="mt-0.5 text-text-primary">{item.external ? <WebsiteLink value={item.value} /> : item.value}</dd>
        </div>
      ))}
    </dl>
  )
}

function WebsiteLink({ value }: { value: string }) {
  try {
    const url = new URL(value)
    if (url.protocol !== "http:" && url.protocol !== "https:") return value
    return (
      <LinkText external href={url.href}>
        {url.host}
      </LinkText>
    )
  } catch {
    return value
  }
}

function Counts({ counts, prominent = false }: { counts: TeamProfileCounts; prominent?: boolean }) {
  const { t } = useT("team_directory")
  if (prominent) {
    return (
      <Metric.Group aria-label={t("profiles.work_counts")} className="mt-6 border-t border-border pt-5" columns={4} role="group">
        <Metric.Card label={t("profiles.count_repos")} value={counts.repositories} />
        <Metric.Card label={t("profiles.count_epics")} value={counts.epics} />
        <Metric.Card label={t("profiles.count_jobs")} value={counts.jobs} />
        <Metric.Card label={t("profiles.count_open")} value={counts.open_jobs} />
      </Metric.Group>
    )
  }
  return (
    <dl className="mt-4 grid grid-cols-4 gap-2 text-center text-xs">
      <Count label={t("profiles.count_repos")} value={counts.repositories} />
      <Count label={t("profiles.count_epics")} value={counts.epics} />
      <Count label={t("profiles.count_jobs")} value={counts.jobs} />
      <Count label={t("profiles.count_open")} value={counts.open_jobs} />
    </dl>
  )
}

function Count({ label, value }: { label: string; value: number }) {
  const { t } = useT("team_directory")
  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 px-2 py-2">
      <dt className="text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="mt-0.5 font-semibold text-gray-900 dark:text-gray-100">{value}</dd>
    </div>
  )
}

function SummaryList<T>({ title, empty, items, renderItem }: { title: string; empty: string; items: T[]; prefix: string; renderItem: (item: T) => ReactNode }) {
  return (
    <Section.Root divided>
      <Section.Header>
        <Section.Title>{title}</Section.Title>
      </Section.Header>
      <Section.Body>
        {items.length === 0 ? (
          <Text muted>{empty}</Text>
        ) : (
          <div className="divide-y divide-border">
            {items.map((item, index) => (
              <div className="py-3 first:pt-0 last:pb-0" key={index}>
                {renderItem(item)}
              </div>
            ))}
          </div>
        )}
      </Section.Body>
    </Section.Root>
  )
}

function RepositoryRow({ repository, prefix }: { repository: TeamProfileRepository; prefix: string }) {
  return (
    <Link className="font-mono text-sm text-brand hover:underline" to={withRoutePrefix(repository.path, prefix)}>
      {repository.slug}
    </Link>
  )
}

function ActivityRow({ activity, prefix }: { activity: TeamProfileActivity; prefix: string }) {
  const { t } = useT("team_directory")
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="min-w-0">
        <Link className="font-medium text-brand hover:underline" to={withRoutePrefix(activity.path, prefix)}>
          {activity.title}
        </Link>
        <div className="mt-1 text-xs text-text-muted">
          {t(`profiles.${activity.type}`)} · {activity.repository_slug} ·{" "}
          <RelativeTimestamp fallback={t("profiles.not_started")} value={activity.occurred_at} />
        </div>
      </div>
      <StatusPill state={activity.state} />
    </div>
  )
}

function ProfilesError({ error }: { error: Error }) {
  const { t } = useT("team_directory")
  const message = error instanceof ApiError ? error.message : t("profiles.load_error")
  return <PanelMessage tone="error">{message}</PanelMessage>
}

// Single entry point for the plugin sidebar page. PluginSidebarPageRoute
// matches `/profiles` and anything beneath it with one component, so the
// index/detail split is decided here from the route params.
export default function TeamDirectory() {
  const { id } = useParams()

  return id ? <TeamProfileRoute /> : <TeamDirectoryRoute />
}
