import "./styles.css"
import { FormEvent, useEffect, useState } from "react"
import { useQuery } from "@tanstack/react-query"

type AuthState = "loading" | "authenticated" | "setup"

const REFRESH_INTERVAL_MS = 30_000

const normalizeInstanceUrl = (url: string) => url.trim().replace(/\/+$/, "")

const jobTitle = (job: SyrusJobItem) => job.title || job.issue_title || `JOB-${job.id}`

const relativeTime = (timestamp: string) => {
  const value = Date.parse(timestamp)
  if (Number.isNaN(value)) {
    return ""
  }

  const seconds = Math.round((value - Date.now()) / 1000)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1]
  ]
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  const [unit, unitSeconds] =
    units.find(([, unitSeconds]) => Math.abs(seconds) >= unitSeconds) ?? units[units.length - 1]

  return formatter.format(Math.round(seconds / unitSeconds), unit)
}

function RefreshIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M21 12a9 9 0 0 1-15.4 6.4L3 16" />
      <path d="M3 21v-5h5" />
      <path d="M3 12a9 9 0 0 1 15.4-6.4L21 8" />
      <path d="M21 3v5h-5" />
    </svg>
  )
}

function ExternalIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M15 3h6v6" />
      <path d="M10 14 21 3" />
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
    </svg>
  )
}

function GitPullRequestIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <circle cx="18" cy="18" r="3" />
      <circle cx="6" cy="6" r="3" />
      <path d="M6 9v12" />
      <path d="M18 15V8a2 2 0 0 0-2-2h-5" />
      <path d="m14 9-3-3 3-3" />
    </svg>
  )
}

function TerminalIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="m4 17 6-6-6-6" />
      <path d="M12 19h8" />
    </svg>
  )
}

function InboxView({ instanceUrl }: { instanceUrl: string }) {
  const inboxQuery = useQuery({
    queryKey: ["inbox-jobs"],
    queryFn: () => window.syrusDesktop.fetchInboxJobs(),
    refetchInterval: REFRESH_INTERVAL_MS
  })
  const jobs = inboxQuery.data ?? []

  const openJob = (job: SyrusJobItem) => {
    void window.syrusDesktop.openExternal(`${normalizeInstanceUrl(instanceUrl)}/jobs/${job.id}`)
  }

  const openPullRequest = (job: SyrusJobItem) => {
    if (job.pr_url) {
      void window.syrusDesktop.openExternal(job.pr_url)
    }
  }

  return (
    <main className="flex min-h-screen flex-col bg-slate-50 text-slate-950">
      <header className="flex items-center justify-between border-b border-slate-200 bg-white px-4 py-3">
        <div className="flex min-w-0 items-center gap-2">
          <div className="grid h-7 w-7 shrink-0 place-items-center rounded-md bg-slate-950 text-sm font-bold text-white">
            S
          </div>
          <div className="min-w-0">
            <p className="truncate text-sm font-bold leading-5">Syrus</p>
            <p className="truncate text-xs text-slate-500">{normalizeInstanceUrl(instanceUrl)}</p>
          </div>
        </div>
        <button
          type="button"
          className="icon-button"
          title="Refresh inbox"
          aria-label="Refresh inbox"
          disabled={inboxQuery.isFetching}
          onClick={() => void inboxQuery.refetch()}
        >
          <RefreshIcon />
        </button>
      </header>

      <section className="min-h-0 flex-1 overflow-y-auto">
        {inboxQuery.isLoading ? (
          <StatusPanel title="Loading inbox" />
        ) : inboxQuery.isError ? (
          <StatusPanel
            title="Could not load inbox"
            detail={inboxQuery.error instanceof Error ? inboxQuery.error.message : "Try again in a moment."}
            actionLabel="Retry"
            onAction={() => void inboxQuery.refetch()}
          />
        ) : jobs.length === 0 ? (
          <StatusPanel title="Nothing in your inbox" detail="Implemented and failed jobs will appear here." />
        ) : (
          <ul className="divide-y divide-slate-200">
            {jobs.map((job) => (
              <JobRow
                key={`${job.state}-${job.id}`}
                job={job}
                onOpenJob={() => openJob(job)}
                onOpenPullRequest={() => openPullRequest(job)}
              />
            ))}
          </ul>
        )}
      </section>
    </main>
  )
}

function StatusPanel({
  title,
  detail,
  actionLabel,
  onAction
}: {
  title: string
  detail?: string
  actionLabel?: string
  onAction?: () => void
}) {
  return (
    <div className="grid min-h-[360px] place-items-center px-6 text-center">
      <div className="max-w-64">
        <p className="text-sm font-semibold text-slate-800">{title}</p>
        {detail ? <p className="mt-2 text-sm leading-5 text-slate-500">{detail}</p> : null}
        {actionLabel && onAction ? (
          <button type="button" className="mt-4 rounded-md border border-slate-300 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-white" onClick={onAction}>
            {actionLabel}
          </button>
        ) : null}
      </div>
    </div>
  )
}

function JobRow({
  job,
  onOpenJob,
  onOpenPullRequest
}: {
  job: SyrusJobItem
  onOpenJob: () => void
  onOpenPullRequest: () => void
}) {
  const isFailed = job.state === "failed"

  return (
    <li className="group flex gap-3 px-4 py-3 hover:bg-white">
      <div className="min-w-0 flex-1">
        <div className="flex items-start gap-2">
          <p className="min-w-0 flex-1 truncate text-sm font-semibold text-slate-950">{jobTitle(job)}</p>
          <span
            className={[
              "shrink-0 rounded-full px-2 py-0.5 text-[11px] font-bold uppercase leading-4",
              isFailed ? "bg-red-100 text-red-700" : "bg-emerald-100 text-emerald-700"
            ].join(" ")}
          >
            {job.state}
          </span>
        </div>
        <div className="mt-1 flex min-w-0 items-center gap-2 text-xs text-slate-500">
          <span className="truncate">{job.repository_slug}</span>
          <span aria-hidden="true">/</span>
          <span className="shrink-0">{relativeTime(job.updated_at)}</span>
        </div>
      </div>

      <div className="flex shrink-0 items-center gap-1 opacity-100 sm:opacity-0 sm:transition-opacity sm:group-hover:opacity-100 sm:group-focus-within:opacity-100">
        <button type="button" className="icon-button" title="Open in Syrus" aria-label={`Open JOB-${job.id} in Syrus`} onClick={onOpenJob}>
          <ExternalIcon />
        </button>
        <button
          type="button"
          className="icon-button"
          title={job.pr_url ? "Open PR" : "No PR yet"}
          aria-label={job.pr_url ? `Open PR for JOB-${job.id}` : `No PR yet for JOB-${job.id}`}
          disabled={!job.pr_url}
          onClick={onOpenPullRequest}
        >
          <GitPullRequestIcon />
        </button>
        <button
          type="button"
          className="icon-button"
          title="Configure local projects root in Preferences"
          aria-label={`Checkout JOB-${job.id} locally`}
          disabled
        >
          <TerminalIcon />
        </button>
      </div>
    </li>
  )
}

export function App() {
  const isPreferencesView = new URLSearchParams(window.location.search).get("view") === "preferences"
  const [authState, setAuthState] = useState<AuthState>("loading")
  const [url, setUrl] = useState("")
  const [token, setToken] = useState("")
  const [error, setError] = useState("")
  const [isSaving, setIsSaving] = useState(false)

  useEffect(() => {
    let isMounted = true

    window.syrusDesktop
      .getCredentials()
      .then((credentials) => {
        if (!isMounted) {
          return
        }

        if (credentials) {
          setUrl(credentials.url)
          setToken(credentials.token)
          setAuthState(isPreferencesView ? "setup" : "authenticated")
        } else {
          setAuthState("setup")
        }
      })
      .catch(() => {
        if (isMounted) {
          setAuthState("setup")
        }
      })

    const unsubscribe = window.syrusDesktop.onCredentialsCleared(() => {
      setToken("")
      setError("")
      setAuthState("setup")
    })

    return () => {
      isMounted = false
      unsubscribe()
    }
  }, [isPreferencesView])

  const saveCredentials = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError("")
    setIsSaving(true)

    try {
      const credentials = await window.syrusDesktop.saveCredentials({ url, token })
      setUrl(credentials.url)
      setToken(credentials.token)
      setAuthState("authenticated")
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save credentials.")
    } finally {
      setIsSaving(false)
    }
  }

  if (authState === "loading") {
    return (
      <main className="shell">
        <section className="panel panel--status" aria-label="Loading Syrus Desktop">
          <p className="eyebrow">Syrus Desktop</p>
          <h1>Loading</h1>
        </section>
      </main>
    )
  }

  if (authState === "setup") {
    return (
      <main className="shell">
        <section className="panel" aria-label="Syrus Desktop settings">
          <div>
            <p className="eyebrow">Syrus Desktop</p>
            <h1>Connect Syrus</h1>
          </div>

          <form className="settings-form" onSubmit={saveCredentials}>
            <label>
              <span>Syrus instance URL</span>
              <input
                autoFocus
                required
                type="url"
                value={url}
                placeholder="https://your-syrus-instance.com"
                onChange={(event) => setUrl(event.target.value)}
              />
            </label>

            <label>
              <span>API token</span>
              <input
                required
                type="password"
                value={token}
                autoComplete="off"
                onChange={(event) => setToken(event.target.value)}
              />
            </label>

            {error ? <p className="form-error">{error}</p> : null}

            <div className="form-actions">
              <button type="button" className="link-button" onClick={() => window.syrusDesktop.openTokenDocs()}>
                Generate a token
              </button>
              <button type="submit" disabled={isSaving}>
                {isSaving ? "Saving..." : "Save"}
              </button>
            </div>
          </form>
        </section>
      </main>
    )
  }

  return (
    <InboxView instanceUrl={url} />
  )
}
