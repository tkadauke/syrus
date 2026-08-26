import { useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { useT } from "../hooks/useT"
import { fetchDeploy, fetchPreview, fetchPreviewLogs, startDeploy, startPreview, stopPreview, type DeployWorkflowRecord, type PreviewEnvironmentRecord } from "../api/jobs"
import { createDirectJob } from "../api/directJobs"
import { errorMessage } from "../lib/errorMessage"
import { Button, buttonClasses } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const ACTIVE_STATES = ["starting", "seeding", "running", "stopping"] as const
const ACTIVE_DEPLOY_STATES = ["queued", "running"] as const
const POLL_INTERVAL_MS = 3000

function isActive(state: PreviewEnvironmentRecord["state"]) {
  return (ACTIVE_STATES as readonly string[]).includes(state)
}

function isDeployActive(state: DeployWorkflowRecord["state"]) {
  return (ACTIVE_DEPLOY_STATES as readonly string[]).includes(state)
}

// Task language for the coding agent, not UI copy — always English regardless
// of the operator's locale, matching every other prompt-generation path.
function buildPreviewFixPrompt(errorMessage: string) {
  return `Syrus's preview feature diagnosed this repository's preview process as unreachable:

"${errorMessage}"

The app starts and passes its own local health check, but is not reachable from the network host Syrus's preview proxy uses to reach it. This almost always means the preview start command binds its server to 127.0.0.1/localhost only instead of all interfaces.

Please fix this repository's preview start command (in .syrus.yml's \`preview.start\`, or the equivalent dev-server start script) so the app binds to 0.0.0.0 while still listening on the port Syrus provides. Common fixes: pass a \`-b 0.0.0.0\` / \`--host 0.0.0.0\` flag to the server command, or change a hardcoded 127.0.0.1/localhost bind host in code or config to 0.0.0.0. Verify the fix doesn't regress normal local usage.`
}

function useCountdown(expiresAt: string | null) {
  const [remaining, setRemaining] = useState<string | null>(null)

  useEffect(() => {
    if (!expiresAt) { setRemaining(null); return }

    function update() {
      const ms = new Date(expiresAt!).getTime() - Date.now()
      if (ms <= 0) { setRemaining(null); return }
      const totalSeconds = Math.floor(ms / 1000)
      const minutes = Math.floor(totalSeconds / 60)
      const seconds = totalSeconds % 60
      setRemaining(`${minutes}m ${String(seconds).padStart(2, "0")}s`)
    }

    update()
    const id = window.setInterval(update, 1000)
    return () => window.clearInterval(id)
  }, [expiresAt])

  return remaining
}

// Shared preview control panel for both job-scoped previews (JobDetail) and
// repository-scoped "preview main" previews (RepositoryDetail) — both hit the
// same PreviewEnvironment/PreviewProxyMiddleware machinery server-side, just
// scoped to a different owning record. queryKeyPrefix + entityId namespace
// this panel's own TanStack Query cache entries so a job preview and a
// repository preview never collide; queryKey is the caller's own detail
// page cache key, invalidated on every preview state change.
export function PreviewPanel({
  queryKeyPrefix,
  entityId,
  repositoryId,
  previewPath,
  previewLogsPath,
  canStart,
  initialPreview,
  deployPath,
  canDeploy,
  initialDeploy,
  queryKey
}: {
  queryKeyPrefix: string
  entityId: number
  repositoryId: number
  previewPath: string
  previewLogsPath: string
  canStart: boolean
  initialPreview: PreviewEnvironmentRecord | null
  deployPath?: string
  canDeploy?: boolean
  initialDeploy?: DeployWorkflowRecord | null
  queryKey: readonly unknown[]
}) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const location = useLocation()
  const [error, setError] = useState<string | null>(null)
  const [deployError, setDeployError] = useState<string | null>(null)
  const previewQueryKey = [`${queryKeyPrefix}-preview`, entityId] as const
  const deployQueryKey = [`${queryKeyPrefix}-deploy`, entityId] as const

  const preview = useQuery({
    queryKey: previewQueryKey,
    queryFn: () => fetchPreview(previewPath),
    select: (data) => data.preview,
    initialData: { preview: initialPreview },
    refetchInterval: (query) => {
      const env = query.state.data?.preview
      return env && isActive(env.state) ? POLL_INTERVAL_MS : false
    }
  })

  const env = preview.data

  // Workflow/Run/Step state changes only broadcast a granular AppEvent that
  // invalidates the workflows-tab query (see appEvents.ts's
  // workflowOnlyJobEvent routing), not this page's detail query — so, like
  // the preview poll above, this polls itself while a deploy is in flight
  // instead of relying on the live-update channel.
  const deploy = useQuery({
    queryKey: deployQueryKey,
    queryFn: () => fetchDeploy(deployPath as string),
    select: (data) => data.deploy,
    initialData: { deploy: initialDeploy ?? null },
    enabled: Boolean(deployPath),
    refetchInterval: (query) => {
      const workflow = query.state.data?.deploy
      return workflow && isDeployActive(workflow.state) ? POLL_INTERVAL_MS : false
    }
  })

  const deployRecord = deploy.data

  const start = useMutation({
    mutationFn: () => startPreview(previewPath),
    onSuccess: (data) => {
      queryClient.setQueryData(previewQueryKey, { preview: data.preview })
      void queryClient.invalidateQueries({ queryKey })
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("preview_failed")))
  })

  const stop = useMutation({
    mutationFn: () => stopPreview(previewPath),
    onSuccess: (data) => {
      queryClient.setQueryData(previewQueryKey, { preview: data.preview })
      void queryClient.invalidateQueries({ queryKey })
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("preview_failed")))
  })

  const deployMutation = useMutation({
    mutationFn: () => startDeploy(deployPath as string),
    onSuccess: (data) => {
      queryClient.setQueryData(deployQueryKey, { deploy: data.deploy })
      void queryClient.invalidateQueries({ queryKey })
      setDeployError(null)
    },
    onError: (err) => setDeployError(errorMessage(err, t("deploy_failed")))
  })

  const fixPreview = useMutation({
    mutationFn: () => createDirectJob({
      repositoryId: String(repositoryId),
      agentProvider: "",
      title: t("preview_fix_job_title"),
      prompt: buildPreviewFixPrompt(env?.error_message ?? ""),
      priority: "high",
      createMore: false,
      files: [],
      googleDocUrl: ""
    }),
    onSuccess: (created) => navigate(withRoutePrefix(created.redirect_to, routePrefix(location.pathname))),
    onError: (err) => setError(errorMessage(err, t("preview_fix_error")))
  })

  const countdown = useCountdown(env?.state === "running" ? env.expires_at : null)
  const expired = env?.state === "running" && env.expires_at != null && new Date(env.expires_at) <= new Date()

  const showDeploy = Boolean(deployPath) && (canDeploy || Boolean(deployRecord))

  if (!canStart && !env && !showDeploy) return null

  const isPending = start.isPending || stop.isPending

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900" aria-label={t("preview_section")}>
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("preview_section")}</h2>
      <div className="mt-3 space-y-2">
        {(canStart || env) ? (
          <>
            {error ? <p className="text-xs text-red-600 dark:text-red-400" role="alert">{error}</p> : null}
            <PreviewControls
              env={env ?? null}
              canStart={canStart}
              expired={expired}
              isPending={isPending}
              onStart={() => start.mutate()}
              onStop={() => stop.mutate()}
              t={t}
            />
            {env ? <PreviewLogs queryKeyPrefix={queryKeyPrefix} entityId={entityId} previewLogsPath={previewLogsPath} running={env.state === "running"} /> : null}
            {env?.state === "running" && !expired && countdown ? (
              <p className="text-xs text-gray-500 dark:text-gray-400">{t("preview_expires_in", { time: countdown })}</p>
            ) : null}
            {expired ? (
              <p className="text-xs text-amber-600 dark:text-amber-400">{t("preview_expired")}</p>
            ) : null}
            {env?.state === "failed" && env.error_message ? (
              <p className="text-xs text-red-600 dark:text-red-400" role="alert">{env.error_message}</p>
            ) : null}
            {env?.state === "failed" && env.error_reason === "not_reachable" ? (
              <Button
                size="sm"
                disabled={fixPreview.isPending}
                onClick={() => fixPreview.mutate()}
              >
                {t("preview_fix_button")}
              </Button>
            ) : null}
          </>
        ) : null}
        {showDeploy ? (
          <div className={(canStart || env) ? "mt-2 border-t border-gray-100 pt-2 dark:border-gray-800" : ""}>
            {deployError ? <p className="text-xs text-red-600 dark:text-red-400" role="alert">{deployError}</p> : null}
            <DeployControls
              deploy={deployRecord ?? null}
              canDeploy={Boolean(canDeploy)}
              isPending={deployMutation.isPending}
              onDeploy={() => deployMutation.mutate()}
              prefix={routePrefix(location.pathname)}
              t={t}
            />
          </div>
        ) : null}
      </div>
    </section>
  )
}

function PreviewLogs({ queryKeyPrefix, entityId, previewLogsPath, running }: { queryKeyPrefix: string; entityId: number; previewLogsPath: string; running: boolean }) {
  const { t } = useT("jobs")
  const [open, setOpen] = useState(false)

  return (
    <div className="pt-1">
      <button
        className="text-xs font-medium text-gray-600 underline decoration-gray-300 underline-offset-2 hover:text-gray-900 dark:text-gray-300 dark:hover:text-gray-100"
        onClick={() => setOpen(true)}
        type="button"
      >
        {t("preview_view_logs")}
      </button>
      {open ? (
        <PreviewLogsModal
          queryKeyPrefix={queryKeyPrefix}
          entityId={entityId}
          onClose={() => setOpen(false)}
          previewLogsPath={previewLogsPath}
          running={running}
        />
      ) : null}
    </div>
  )
}

function PreviewLogsModal({
  queryKeyPrefix,
  entityId,
  previewLogsPath,
  running,
  onClose
}: {
  queryKeyPrefix: string
  entityId: number
  previewLogsPath: string
  running: boolean
  onClose: () => void
}) {
  const { t } = useT("jobs")
  const closeRef = useRef<HTMLButtonElement>(null)

  const logs = useQuery({
    queryKey: [`${queryKeyPrefix}-preview-logs`, entityId],
    queryFn: () => fetchPreviewLogs(previewLogsPath),
    refetchInterval: running ? POLL_INTERVAL_MS : false
  })

  useEffect(() => {
    closeRef.current?.focus()
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onClose}
    >
      <section
        aria-labelledby="preview-logs-modal-title"
        aria-modal="true"
        className="flex max-h-[80vh] w-full max-w-2xl flex-col rounded-lg bg-white shadow-xl dark:bg-gray-900"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
      >
        <div className="flex items-center justify-between border-b border-gray-200 p-4 dark:border-gray-700">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="preview-logs-modal-title">
            {t("preview_logs_modal_title")}
          </h2>
          <button
            aria-label={t("preview_logs_close")}
            className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-800 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100"
            onClick={onClose}
            ref={closeRef}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <div className="space-y-2 overflow-auto p-4">
          {logs.isPending ? <p className="text-xs text-gray-500 dark:text-gray-400">{t("preview_logs_loading")}</p> : null}
          {logs.isError ? <p className="text-xs text-red-600 dark:text-red-400">{t("preview_logs_error")}</p> : null}
          {logs.data?.logs.length === 0 ? <p className="text-xs text-gray-500 dark:text-gray-400">{t("preview_logs_empty")}</p> : null}
          {logs.data?.logs.map((log) => (
            <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700" key={log.path}>
              <div className="flex items-center justify-between bg-gray-50 px-2 py-1 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">
                <span>{log.path}</span>
                {log.missing ? <span className="text-amber-600 dark:text-amber-400">{t("preview_logs_missing")}</span> : null}
              </div>
              <pre className="max-h-56 overflow-auto bg-gray-950 p-2 text-2xs leading-4 text-gray-100">{log.missing ? "" : log.content || t("preview_logs_empty_content")}</pre>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}

function PreviewControls({
  env,
  canStart,
  expired,
  isPending,
  onStart,
  onStop,
  t
}: {
  env: PreviewEnvironmentRecord | null
  canStart: boolean
  expired: boolean
  isPending: boolean
  onStart: () => void
  onStop: () => void
  t: ReturnType<typeof useT>["t"]
}) {
  const state = env?.state

  if (!state || state === "stopped" || state === "failed") {
    if (!canStart && !expired) return null
    return (
      <Button
        size="sm"
        disabled={isPending}
        onClick={onStart}
      >
        {t("preview_start")}
      </Button>
    )
  }

  if (state === "starting") {
    return (
      <span className="inline-flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
        <Spinner />
        {t("preview_starting")}
      </span>
    )
  }

  if (state === "seeding") {
    return (
      <span className="inline-flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
        <Spinner />
        {t("preview_seeding")}
      </span>
    )
  }

  if (state === "stopping") {
    return (
      <span className="inline-flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
        <Spinner />
        {t("preview_stopping")}
      </span>
    )
  }

  if (state === "running") {
    if (expired) {
      return (
        <Button
          size="sm"
          disabled={isPending}
          onClick={onStart}
        >
          {t("preview_restart")}
        </Button>
      )
    }

    return (
      <div className="flex flex-wrap items-center gap-2">
        <a
          className={buttonClasses("success", "sm")}
          href={env!.url ?? "#"}
          rel="noopener noreferrer"
          target="_blank"
        >
          {t("preview_open")}
        </a>
        <Button
          variant="secondary"
          size="sm"
          disabled={isPending}
          onClick={onStop}
        >
          {t("preview_stop")}
        </Button>
      </div>
    )
  }

  return null
}

function DeployControls({
  deploy,
  canDeploy,
  isPending,
  onDeploy,
  prefix,
  t
}: {
  deploy: DeployWorkflowRecord | null
  canDeploy: boolean
  isPending: boolean
  onDeploy: () => void
  prefix: string
  t: ReturnType<typeof useT>["t"]
}) {
  const state = deploy?.state
  const deployButton = canDeploy ? (
    <button
      className="rounded border border-terracotta-600 px-3 py-1.5 text-xs font-medium text-terracotta-700 hover:bg-terracotta-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-terracotta-500 dark:text-terracotta-400 dark:hover:bg-gray-800"
      disabled={isPending}
      onClick={onDeploy}
      type="button"
    >
      {state ? t("deploy_again_button") : t("deploy_button")}
    </button>
  ) : null

  if (!state) return deployButton

  const viewLink = (
    <Link className="text-xs font-medium text-gray-600 underline decoration-gray-300 underline-offset-2 hover:text-gray-900 dark:text-gray-300 dark:hover:text-gray-100" to={withRoutePrefix(deploy!.path, prefix)}>
      {t("deploy_view")}
    </Link>
  )

  if (state === "queued" || state === "running") {
    return (
      <div className="flex flex-wrap items-center gap-2">
        <span className="inline-flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
          <Spinner />
          {state === "queued" ? t("deploy_queued") : t("deploy_running")}
        </span>
        {viewLink}
      </div>
    )
  }

  const statusLabel = state === "succeeded"
    ? <span className="text-xs font-medium text-emerald-700 dark:text-emerald-400">{t("deploy_succeeded")}</span>
    : <span className="text-xs font-medium text-red-600 dark:text-red-400">{state === "cancelled" ? t("deploy_cancelled") : t("deploy_failed_status")}</span>

  return (
    <div className="flex flex-wrap items-center gap-2">
      {statusLabel}
      {viewLink}
      {deployButton}
    </div>
  )
}

function Spinner() {
  return (
    <svg aria-hidden="true" className="h-3 w-3 animate-spin text-gray-400" fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" fill="currentColor" />
    </svg>
  )
}

export function PreviewStopModal({
  onStop,
  onKeepRunning
}: {
  onStop: () => void
  onKeepRunning: () => void
}) {
  const { t } = useT("jobs")
  const cancelRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    cancelRef.current?.focus()
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onKeepRunning()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onKeepRunning])

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onKeepRunning}
    >
      <section
        aria-labelledby="preview-stop-modal-title"
        aria-modal="true"
        className="w-full max-w-md rounded-lg bg-white shadow-xl dark:bg-gray-900"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
      >
        <div className="space-y-4 p-5">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="preview-stop-modal-title">
            {t("preview_stop_on_action_title")}
          </h2>
          <p className="text-sm text-gray-700 dark:text-gray-300">{t("preview_stop_on_action_body")}</p>
          <div className="flex justify-end gap-3">
            <Button
              variant="secondary"
              onClick={onKeepRunning}
              ref={cancelRef}
            >
              {t("preview_keep_running")}
            </Button>
            <Button
              variant="danger"
              onClick={onStop}
            >
              {t("preview_stop_yes")}
            </Button>
          </div>
        </div>
      </section>
    </div>
  )
}
