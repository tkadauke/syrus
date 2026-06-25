import "./styles.css"
import { FormEvent, type RefObject, useEffect, useRef, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { RepoPicker } from "./RepoPicker"

type AuthState = "loading" | "authenticated" | "setup"
type PreferencesTab = "account" | "projects"
type CheckoutStatusByRepo = Record<string, SyrusCheckoutAvailability>
type ToastState = {
  kind: "success" | "error"
  message: string
  copyCommand?: string
  actionLabel?: string
  actionUrl?: string
}
type RepoPathDraft = {
  id: string
  repoSlug: string
  localPath: string
}

const REFRESH_INTERVAL_MS = 30_000
const EMPTY_JOBS: SyrusJobItem[] = []

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

function ComposeIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M12 5v14" />
      <path d="M5 12h14" />
    </svg>
  )
}

function CheckIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.25">
      <path d="M20 6 9 17l-5-5" />
    </svg>
  )
}

function InboxView({ instanceUrl }: { instanceUrl: string }) {
  const queryClient = useQueryClient()
  const [checkoutStatusByRepo, setCheckoutStatusByRepo] = useState<CheckoutStatusByRepo>({})
  const [pendingApprovals, setPendingApprovals] = useState<Set<number>>(() => new Set())
  const [toast, setToast] = useState<ToastState | null>(null)
  const [isComposeOpen, setIsComposeOpen] = useState(false)
  const composeRef = useRef<HTMLElement>(null)
  const composeButtonRef = useRef<HTMLButtonElement>(null)
  const inboxQuery = useQuery({
    queryKey: ["inbox-jobs", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchInboxJobs(),
    refetchInterval: REFRESH_INTERVAL_MS
  })
  const cliStatusQuery = useQuery({
    queryKey: ["syrus-cli-status"],
    queryFn: () => window.syrusDesktop.syrusCliStatus()
  })
  const bootstrapQuery = useQuery({
    queryKey: ["bootstrap", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchBootstrap(),
    staleTime: REFRESH_INTERVAL_MS
  })
  const isAdmin = bootstrapQuery.data?.current_user?.admin === true
  const adminControlsQuery = useQuery({
    queryKey: ["admin-controls", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchAdminControls(),
    enabled: isAdmin,
    refetchInterval: isAdmin ? REFRESH_INTERVAL_MS : false
  })
  const jobs = inboxQuery.data ?? EMPTY_JOBS

  const showErrorToast = (message: string) => {
    setToast({ kind: "error", message })
    window.setTimeout(() => setToast(null), 3200)
  }

  useEffect(() => {
    if (jobs.length === 0) {
      setCheckoutStatusByRepo({})
      return
    }

    let isMounted = true
    const repoSlugs = Array.from(new Set(jobs.map((job) => job.repository_slug).filter(Boolean)))

    Promise.all(
      repoSlugs.map(async (repoSlug) => {
        const status = await window.syrusDesktop.checkoutAvailability(repoSlug)
        return [repoSlug, status] as const
      })
    )
      .then((entries) => {
        if (isMounted) {
          setCheckoutStatusByRepo(Object.fromEntries(entries))
        }
      })
      .catch(() => {
        if (isMounted) {
          setCheckoutStatusByRepo({})
        }
      })

    return () => {
      isMounted = false
    }
  }, [jobs])

  useEffect(() => {
    const unsubscribe = window.syrusDesktop.onDesktopSettingsUpdated(() => {
      void cliStatusQuery.refetch()
      void inboxQuery.refetch()
    })

    return unsubscribe
  }, [cliStatusQuery, inboxQuery])

  const openJob = (job: SyrusJobItem) => {
    void window.syrusDesktop.openExternal(`${normalizeInstanceUrl(instanceUrl)}/jobs/${job.id}`)
  }

  const openPullRequest = (job: SyrusJobItem) => {
    if (job.pr_url) {
      void window.syrusDesktop.openExternal(job.pr_url)
    }
  }

  const checkoutJob = async (job: SyrusJobItem) => {
    const command = `syrus checkout JOB-${job.id}`
    setToast(null)

    try {
      const result = await window.syrusDesktop.checkoutJob({
        jobRef: `JOB-${job.id}`,
        repoSlug: job.repository_slug,
        branchName: job.branch_name
      })
      setToast({ kind: "success", message: `Checked out ${result.branchName}` })
    } catch (checkoutError) {
      setToast({
        kind: "error",
        message: checkoutError instanceof Error ? checkoutError.message : "Local checkout failed.",
        copyCommand: command
      })
    }
  }

  const approveJob = async (job: SyrusJobItem) => {
    setToast(null)

    try {
      const confirmed = await window.syrusDesktop.confirmApproveJob(job.id)
      if (!confirmed) {
        return
      }

      setPendingApprovals((current) => new Set(current).add(job.id))
      await window.syrusDesktop.approveJob(job.id)
      queryClient.setQueryData<SyrusJobItem[]>(["inbox-jobs", instanceUrl], (currentJobs = []) =>
        currentJobs.map((currentJob) => currentJob.id === job.id ? { ...currentJob, state: "approved", summary_state: "approved" } : currentJob)
      )
      setToast({ kind: "success", message: `JOB-${job.id} approved` })
      window.setTimeout(() => setToast(null), 2400)
      void inboxQuery.refetch()
    } catch (approvalError) {
      setToast({
        kind: "error",
        message: approvalError instanceof Error ? approvalError.message : `Could not approve JOB-${job.id}.`
      })
    } finally {
      setPendingApprovals((current) => {
        const next = new Set(current)
        next.delete(job.id)
        return next
      })
    }
  }

  const copyToastCommand = () => {
    if (toast?.copyCommand) {
      void window.syrusDesktop.copyText(toast.copyCommand)
    }
  }

  const openToastAction = () => {
    if (toast?.actionUrl) {
      void window.syrusDesktop.openExternal(toast.actionUrl)
    }
  }

  useEffect(() => {
    if (!isComposeOpen) {
      return
    }

    const collapseOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsComposeOpen(false)
      }
    }

    const collapseOnOutsideClick = (event: MouseEvent) => {
      const target = event.target as Node
      if (!composeRef.current?.contains(target) && !composeButtonRef.current?.contains(target)) {
        setIsComposeOpen(false)
      }
    }

    const collapseOnBlur = () => setIsComposeOpen(false)

    document.addEventListener("keydown", collapseOnEscape)
    document.addEventListener("mousedown", collapseOnOutsideClick)
    window.addEventListener("blur", collapseOnBlur)

    return () => {
      document.removeEventListener("keydown", collapseOnEscape)
      document.removeEventListener("mousedown", collapseOnOutsideClick)
      window.removeEventListener("blur", collapseOnBlur)
    }
  }, [isComposeOpen])

  const handleComposeSuccess = (result: SyrusCreateJobResponse, repoSlug: string) => {
    setIsComposeOpen(false)
    setToast({
      kind: "success",
      message: `Job queued in ${repoSlug}`,
      actionLabel: "Open in Syrus",
      actionUrl: `${normalizeInstanceUrl(instanceUrl)}${result.redirect_to}`
    })
    void inboxQuery.refetch()
  }

  const cliMissing = cliStatusQuery.data?.available === false

  return (
    <main className="relative flex h-screen min-h-screen flex-col bg-slate-50 text-slate-950">
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
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            className="icon-button"
            title={isComposeOpen ? "Close compose" : "Compose job"}
            aria-label={isComposeOpen ? "Close job compose" : "Compose job"}
            aria-pressed={isComposeOpen}
            ref={composeButtonRef}
            onClick={() => setIsComposeOpen((open) => !open)}
          >
            <ComposeIcon />
          </button>
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
        </div>
      </header>

      {cliMissing ? (
        <div className="border-b border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-5 text-amber-900">
          <span>Install the Syrus CLI to enable local branch checkout.</span>{" "}
          <button type="button" className="inline-link" onClick={() => window.syrusDesktop.openTokenDocs()}>
            Install docs
          </button>
        </div>
      ) : null}

      {toast ? (
        <div
          className={[
            "mx-3 mt-3 rounded-md border px-3 py-2 text-sm leading-5",
            toast.kind === "success"
              ? "border-emerald-200 bg-emerald-50 text-emerald-800"
              : "border-red-200 bg-red-50 text-red-800"
          ].join(" ")}
          role="status"
        >
          <div className="flex items-start justify-between gap-3">
            <span className="min-w-0 overflow-wrap-anywhere">{toast.message}</span>
            {toast.copyCommand ? (
              <button type="button" className="toast-action" onClick={copyToastCommand}>
                Copy command
              </button>
            ) : null}
            {toast.actionLabel && toast.actionUrl ? (
              <button type="button" className="toast-action" onClick={openToastAction}>
                {toast.actionLabel}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}

      <section className="min-h-0 flex-1 overflow-y-auto">
        {isComposeOpen ? (
          <ComposePanel
            panelRef={composeRef}
            onCancel={() => setIsComposeOpen(false)}
            onSuccess={handleComposeSuccess}
          />
        ) : inboxQuery.isLoading ? (
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
                checkoutStatus={checkoutStatusByRepo[job.repository_slug]}
                cliAvailable={cliStatusQuery.data?.available ?? false}
                onOpenJob={() => openJob(job)}
                onOpenPullRequest={() => openPullRequest(job)}
                onCheckout={() => void checkoutJob(job)}
                onApprove={() => void approveJob(job)}
                approving={pendingApprovals.has(job.id)}
                optimisticState={pendingApprovals.has(job.id) ? "approved" : undefined}
              />
            ))}
          </ul>
        )}
      </section>

      {isAdmin ? (
        <AdminControlsFooter
          controls={adminControlsQuery.data}
          disabled={adminControlsQuery.isLoading || adminControlsQuery.isFetching}
          onError={showErrorToast}
          onRefresh={() => void adminControlsQuery.refetch()}
        />
      ) : null}
    </main>
  )
}

function AdminControlsFooter({
  controls,
  disabled,
  onError,
  onRefresh
}: {
  controls?: SyrusAdminControls
  disabled: boolean
  onError: (message: string) => void
  onRefresh: () => void
}) {
  const [pendingControl, setPendingControl] = useState<SyrusAdminControl | null>(null)

  const toggle = async (control: SyrusAdminControl, pause: boolean) => {
    setPendingControl(control)

    try {
      const result = await window.syrusDesktop.toggleAdminControl(control, pause)
      if (!result.cancelled) {
        onRefresh()
      }
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update admin controls.")
    } finally {
      setPendingControl(null)
    }
  }

  return (
    <footer className="border-t border-slate-200 bg-white/95 px-4 py-2">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[11px] font-semibold uppercase leading-4 text-slate-400">Admin</p>
        <div className="flex min-w-0 items-center gap-2">
          <AdminControlToggle
            disabled={disabled || pendingControl !== null}
            isPending={pendingControl === "polling"}
            label="Polling"
            paused={controls?.polling_paused}
            onToggle={() => void toggle("polling", controls?.polling_paused !== true)}
          />
          <AdminControlToggle
            disabled={disabled || pendingControl !== null}
            isPending={pendingControl === "runs"}
            label="Runs"
            paused={controls?.runs_paused}
            onToggle={() => void toggle("runs", controls?.runs_paused !== true)}
          />
        </div>
      </div>
    </footer>
  )
}

function AdminControlToggle({
  label,
  paused,
  disabled,
  isPending,
  onToggle
}: {
  label: string
  paused?: boolean
  disabled: boolean
  isPending: boolean
  onToggle: () => void
}) {
  const isPaused = paused === true
  const isUnknown = paused == null

  return (
    <button
      type="button"
      className={[
        "admin-toggle",
        isPaused ? "admin-toggle--paused" : "admin-toggle--running"
      ].join(" ")}
      disabled={disabled || isUnknown}
      onClick={onToggle}
    >
      <span>{label}</span>
      <span className="admin-toggle__state">
        {isPending ? "Saving" : isUnknown ? "Loading" : isPaused ? "Paused / Resume" : "Running / Pause"}
      </span>
    </button>
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
  checkoutStatus,
  cliAvailable,
  onOpenJob,
  onOpenPullRequest,
  onCheckout,
  onApprove,
  approving,
  optimisticState
}: {
  job: SyrusJobItem
  checkoutStatus?: SyrusCheckoutAvailability
  cliAvailable: boolean
  onOpenJob: () => void
  onOpenPullRequest: () => void
  onCheckout: () => void
  onApprove: () => void
  approving: boolean
  optimisticState?: string
}) {
  const displayState = optimisticState ?? job.state
  const isFailed = displayState === "failed"
  const isImplemented = job.state === "implemented"
  const checkoutEnabled = cliAvailable && Boolean(checkoutStatus?.localPath)
  const checkoutTitle = !cliAvailable
    ? "Install the Syrus CLI to enable local branch checkout"
    : checkoutStatus?.localPath
      ? `Checkout in ${checkoutStatus.localPath}`
      : "Configure local projects root in Preferences"

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
            {displayState}
          </span>
        </div>
        <div className="mt-1 flex min-w-0 items-center gap-2 text-xs text-slate-500">
          <span className="truncate">{job.repository_slug}</span>
          <span aria-hidden="true">/</span>
          <span className="shrink-0">{relativeTime(job.updated_at)}</span>
        </div>
      </div>

      <div className="flex shrink-0 items-center gap-1 opacity-100 sm:opacity-0 sm:transition-opacity sm:group-hover:opacity-100 sm:group-focus-within:opacity-100">
        {isImplemented ? (
          <button
            type="button"
            className="icon-button icon-button--success"
            title="Approve for landing"
            aria-label={`Approve JOB-${job.id} for landing`}
            disabled={approving}
            onClick={onApprove}
          >
            <CheckIcon />
          </button>
        ) : null}
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
          title={checkoutTitle}
          aria-label={`Checkout JOB-${job.id} locally`}
          disabled={!checkoutEnabled}
          onClick={onCheckout}
        >
          <TerminalIcon />
        </button>
      </div>
    </li>
  )
}

function ComposePanel({
  panelRef,
  onCancel,
  onSuccess
}: {
  panelRef?: RefObject<HTMLElement>
  onCancel: () => void
  onSuccess: (result: SyrusCreateJobResponse, repoSlug: string) => void
}) {
  const [repoSlug, setRepoSlug] = useState("")
  const [prompt, setPrompt] = useState("")
  const [error, setError] = useState("")
  const [isSubmitting, setIsSubmitting] = useState(false)
  const promptRef = useRef<HTMLTextAreaElement>(null)
  const repositoriesQuery = useQuery({
    queryKey: ["repositories"],
    queryFn: () => window.syrusDesktop.fetchRepositories()
  })
  const repositories = repositoriesQuery.data ?? []
  const selectedRepository = repositories.find((repository) => repository.slug === repoSlug) ?? null

  useEffect(() => {
    window.requestAnimationFrame(() => promptRef.current?.focus())
  }, [])

  const resetAndCancel = () => {
    setPrompt("")
    setRepoSlug("")
    setError("")
    onCancel()
  }

  const submitJob = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError("")

    const trimmedPrompt = prompt.trim()
    if (!selectedRepository) {
      setError("Choose a repository.")
      return
    }

    if (trimmedPrompt === "") {
      setError("Prompt can't be blank.")
      return
    }

    setIsSubmitting(true)
    try {
      const result = await window.syrusDesktop.createDirectJob({
        repositoryId: selectedRepository.id,
        prompt: trimmedPrompt
      })
      setPrompt("")
      setRepoSlug("")
      onSuccess(result, selectedRepository.slug)
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "Could not create job.")
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <section className="compose-panel" aria-label="Compose direct job" ref={panelRef}>
      <form className="compose-form" onSubmit={submitJob}>
        <label className="compose-field">
          <span>Prompt</span>
          <textarea
            className="compose-prompt"
            disabled={isSubmitting}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="Describe the job..."
            ref={promptRef}
            required
            rows={7}
            value={prompt}
          />
        </label>

        <label className="compose-field">
          <span>Repository</span>
          <RepoPicker value={repoSlug} onChange={setRepoSlug} disabled={isSubmitting} />
        </label>

        {repositoriesQuery.isError ? <p className="form-error">Could not load repositories.</p> : null}
        {error ? <p className="form-error">{error}</p> : null}

        <div className="form-actions form-actions--end">
          <button type="button" className="secondary-button" disabled={isSubmitting} onClick={resetAndCancel}>
            Cancel
          </button>
          <button type="submit" disabled={isSubmitting || repositoriesQuery.isLoading}>
            {isSubmitting ? "Submitting..." : "Submit"}
          </button>
        </div>
      </form>
    </section>
  )
}

function ComposeView({ instanceUrl }: { instanceUrl: string }) {
  const [toast, setToast] = useState<ToastState | null>(null)

  const handleSuccess = (result: SyrusCreateJobResponse, repoSlug: string) => {
    setToast({
      kind: "success",
      message: `Job queued in ${repoSlug}`,
      actionLabel: "Open in Syrus",
      actionUrl: `${normalizeInstanceUrl(instanceUrl)}${result.redirect_to}`
    })
  }

  return (
    <main className="flex h-screen min-h-screen flex-col bg-slate-50 text-slate-950">
      <header className="border-b border-slate-200 bg-white px-4 py-3">
        <div className="flex min-w-0 items-center gap-2">
          <div className="grid h-7 w-7 shrink-0 place-items-center rounded-md bg-slate-950 text-sm font-bold text-white">
            S
          </div>
          <div className="min-w-0">
            <p className="truncate text-sm font-bold leading-5">New job</p>
            <p className="truncate text-xs text-slate-500">{normalizeInstanceUrl(instanceUrl)}</p>
          </div>
        </div>
      </header>

      {toast ? (
        <div className="mx-3 mt-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm leading-5 text-emerald-800" role="status">
          <div className="flex items-start justify-between gap-3">
            <span className="min-w-0 overflow-wrap-anywhere">{toast.message}</span>
            {toast.actionLabel && toast.actionUrl ? (
              <button type="button" className="toast-action" onClick={() => window.syrusDesktop.openExternal(toast.actionUrl!)}>
                {toast.actionLabel}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}

      <section className="min-h-0 flex-1 overflow-y-auto">
        <ComposePanel onCancel={() => setToast(null)} onSuccess={handleSuccess} />
      </section>
    </main>
  )
}

export function App() {
  const view = new URLSearchParams(window.location.search).get("view")
  const isPreferencesView = view === "preferences"
  const isComposeView = view === "compose"
  const [authState, setAuthState] = useState<AuthState>("loading")
  const [url, setUrl] = useState("")
  const [token, setToken] = useState("")
  const [error, setError] = useState("")
  const [isSaving, setIsSaving] = useState(false)
  const [preferencesTab, setPreferencesTab] = useState<PreferencesTab>("account")
  const [localProjectsRoot, setLocalProjectsRoot] = useState("")
  const [repoPathDrafts, setRepoPathDrafts] = useState<RepoPathDraft[]>([])
  const [settingsError, setSettingsError] = useState("")
  const [settingsSaved, setSettingsSaved] = useState(false)
  const [isSavingSettings, setIsSavingSettings] = useState(false)

  useEffect(() => {
    let isMounted = true

    Promise.all([window.syrusDesktop.getCredentials(), window.syrusDesktop.getDesktopSettings()])
      .then(([credentials, desktopSettings]) => {
        if (!isMounted) {
          return
        }

        setLocalProjectsRoot(desktopSettings.localProjectsRoot)
        setRepoPathDrafts(
          Object.entries(desktopSettings.localRepoPaths).map(([repoSlug, localPath]) => ({
            id: `${repoSlug}-${localPath}`,
            repoSlug,
            localPath
          }))
        )

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
      setAuthState(isPreferencesView ? "setup" : "authenticated")
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save credentials.")
    } finally {
      setIsSaving(false)
    }
  }

  const chooseLocalProjectsRoot = async () => {
    const selectedPath = await window.syrusDesktop.chooseLocalProjectsRoot()
    if (selectedPath) {
      setLocalProjectsRoot(selectedPath)
      setSettingsSaved(false)
    }
  }

  const addRepoPathDraft = () => {
    setRepoPathDrafts((drafts) => [...drafts, { id: crypto.randomUUID(), repoSlug: "", localPath: "" }])
    setSettingsSaved(false)
  }

  const updateRepoPathDraft = (id: string, field: "repoSlug" | "localPath", value: string) => {
    setRepoPathDrafts((drafts) => drafts.map((draft) => (draft.id === id ? { ...draft, [field]: value } : draft)))
    setSettingsSaved(false)
  }

  const removeRepoPathDraft = (id: string) => {
    setRepoPathDrafts((drafts) => drafts.filter((draft) => draft.id !== id))
    setSettingsSaved(false)
  }

  const saveDesktopSettings = async () => {
    setSettingsError("")
    setSettingsSaved(false)
    setIsSavingSettings(true)

    try {
      const settings = await window.syrusDesktop.saveDesktopSettings({
        localProjectsRoot,
        localRepoPaths: Object.fromEntries(
          repoPathDrafts
            .map((draft) => [draft.repoSlug.trim(), draft.localPath.trim()] as const)
            .filter(([repoSlug, localPath]) => repoSlug !== "" && localPath !== "")
        )
      })
      setLocalProjectsRoot(settings.localProjectsRoot)
      setRepoPathDrafts(
        Object.entries(settings.localRepoPaths).map(([repoSlug, localPath]) => ({
          id: `${repoSlug}-${localPath}`,
          repoSlug,
          localPath
        }))
      )
      setSettingsSaved(true)
    } catch (settingsSaveError) {
      setSettingsError(settingsSaveError instanceof Error ? settingsSaveError.message : "Could not save local checkout settings.")
    } finally {
      setIsSavingSettings(false)
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
    const tabClass = (tab: PreferencesTab) => [
      "preferences-tab",
      preferencesTab === tab ? "preferences-tab--active" : ""
    ].join(" ")

    return (
      <main className="shell">
        <section className="panel" aria-label="Syrus Desktop settings">
          <div>
            <p className="eyebrow">Syrus Desktop</p>
            <h1>Connect Syrus</h1>
          </div>

          <div className="preferences-tabs" role="tablist" aria-label="Preferences sections">
            <button
              type="button"
              className={tabClass("account")}
              role="tab"
              aria-selected={preferencesTab === "account"}
              aria-controls="preferences-account-panel"
              id="preferences-account-tab"
              onClick={() => setPreferencesTab("account")}
            >
              Account
            </button>
            <button
              type="button"
              className={tabClass("projects")}
              role="tab"
              aria-selected={preferencesTab === "projects"}
              aria-controls="preferences-projects-panel"
              id="preferences-projects-tab"
              onClick={() => setPreferencesTab("projects")}
            >
              Projects
            </button>
          </div>

          {preferencesTab === "account" ? (
            <form
              className="settings-form"
              id="preferences-account-panel"
              role="tabpanel"
              aria-labelledby="preferences-account-tab"
              onSubmit={saveCredentials}
            >
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
          ) : (
            <div className="settings-form">
              <section
                className="settings-section settings-section--flush"
                id="preferences-projects-panel"
                role="tabpanel"
                aria-labelledby="preferences-projects-tab"
                aria-label="Local checkout settings"
              >
                <div>
                  <h2>Local checkout</h2>
                </div>

                <label>
                  <span>Local projects root</span>
                  <div className="input-with-button">
                    <input
                      type="text"
                      value={localProjectsRoot}
                      placeholder="/Users/you/src"
                      onChange={(event) => {
                        setLocalProjectsRoot(event.target.value)
                        setSettingsSaved(false)
                      }}
                    />
                    <button type="button" className="secondary-button" onClick={chooseLocalProjectsRoot}>
                      Choose
                    </button>
                  </div>
                </label>

                <div className="repo-paths-header">
                  <span>Per-repo overrides</span>
                  <button type="button" className="secondary-button" onClick={addRepoPathDraft}>
                    Add row
                  </button>
                </div>

                {repoPathDrafts.length > 0 ? (
                  <div className="repo-paths-table">
                    {repoPathDrafts.map((draft) => (
                      <div className="repo-path-row" key={draft.id}>
                        <input
                          type="text"
                          value={draft.repoSlug}
                          placeholder="owner/repo"
                          aria-label="Repository slug"
                          onChange={(event) => updateRepoPathDraft(draft.id, "repoSlug", event.target.value)}
                        />
                        <input
                          type="text"
                          value={draft.localPath}
                          placeholder="/absolute/path/to/repo"
                          aria-label="Repository local path"
                          onChange={(event) => updateRepoPathDraft(draft.id, "localPath", event.target.value)}
                        />
                        <button
                          type="button"
                          className="remove-row-button"
                          aria-label={`Remove ${draft.repoSlug || "repository override"}`}
                          onClick={() => removeRepoPathDraft(draft.id)}
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                ) : null}

                {settingsError ? <p className="form-error">{settingsError}</p> : null}
                {settingsSaved ? <p className="form-success">Local checkout settings saved.</p> : null}

                <div className="form-actions form-actions--end">
                  <button type="button" disabled={isSavingSettings} onClick={saveDesktopSettings}>
                    {isSavingSettings ? "Saving..." : "Save local checkout settings"}
                  </button>
                </div>
              </section>
            </div>
          )}
        </section>
      </main>
    )
  }

  return isComposeView ? <ComposeView instanceUrl={url} /> : <InboxView instanceUrl={url} />
}
