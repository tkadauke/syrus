import { useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useT } from "../../hooks/useT"
import { fetchJobPreview, fetchJobPreviewLogs, startJobPreview, stopJobPreview, type PreviewEnvironmentRecord } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { CloseIcon } from "../../components/CloseIcon"
import type { JobDetailQueryKey } from "./queryKeys"

const ACTIVE_STATES = ["starting", "seeding", "running", "stopping"] as const
const POLL_INTERVAL_MS = 3000

function isActive(state: PreviewEnvironmentRecord["state"]) {
  return (ACTIVE_STATES as readonly string[]).includes(state)
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

export function PreviewPanel({
  jobId,
  previewPath,
  previewLogsPath,
  canStart,
  initialPreview,
  queryKey
}: {
  jobId: number
  previewPath: string
  previewLogsPath: string
  canStart: boolean
  initialPreview: PreviewEnvironmentRecord | null
  queryKey: JobDetailQueryKey
}) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const [error, setError] = useState<string | null>(null)

  const preview = useQuery({
    queryKey: ["job-preview", jobId],
    queryFn: () => fetchJobPreview(previewPath),
    select: (data) => data.preview,
    initialData: { preview: initialPreview },
    refetchInterval: (query) => {
      const env = query.state.data?.preview
      return env && isActive(env.state) ? POLL_INTERVAL_MS : false
    }
  })

  const env = preview.data

  const start = useMutation({
    mutationFn: () => startJobPreview(previewPath),
    onSuccess: (data) => {
      queryClient.setQueryData(["job-preview", jobId], { preview: data.preview })
      void queryClient.invalidateQueries({ queryKey })
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("preview_failed")))
  })

  const stop = useMutation({
    mutationFn: () => stopJobPreview(previewPath),
    onSuccess: (data) => {
      queryClient.setQueryData(["job-preview", jobId], { preview: data.preview })
      void queryClient.invalidateQueries({ queryKey })
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("preview_failed")))
  })

  const countdown = useCountdown(env?.state === "running" ? env.expires_at : null)
  const expired = env?.state === "running" && env.expires_at != null && new Date(env.expires_at) <= new Date()

  if (!canStart && !env) return null

  const isPending = start.isPending || stop.isPending

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900" aria-label={t("preview_section")}>
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("preview_section")}</h2>
      <div className="mt-3 space-y-2">
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
        {env ? <PreviewLogs jobId={jobId} previewLogsPath={previewLogsPath} running={env.state === "running"} /> : null}
        {env?.state === "running" && !expired && countdown ? (
          <p className="text-xs text-gray-500 dark:text-gray-400">{t("preview_expires_in", { time: countdown })}</p>
        ) : null}
        {expired ? (
          <p className="text-xs text-amber-600 dark:text-amber-400">{t("preview_expired")}</p>
        ) : null}
        {env?.state === "failed" && env.error_message ? (
          <p className="text-xs text-red-600 dark:text-red-400" role="alert">{env.error_message}</p>
        ) : null}
      </div>
    </section>
  )
}

function PreviewLogs({ jobId, previewLogsPath, running }: { jobId: number; previewLogsPath: string; running: boolean }) {
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
          jobId={jobId}
          onClose={() => setOpen(false)}
          previewLogsPath={previewLogsPath}
          running={running}
        />
      ) : null}
    </div>
  )
}

function PreviewLogsModal({
  jobId,
  previewLogsPath,
  running,
  onClose
}: {
  jobId: number
  previewLogsPath: string
  running: boolean
  onClose: () => void
}) {
  const { t } = useT("jobs")
  const closeRef = useRef<HTMLButtonElement>(null)

  const logs = useQuery({
    queryKey: ["job-preview-logs", jobId],
    queryFn: () => fetchJobPreviewLogs(previewLogsPath),
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
              <pre className="max-h-56 overflow-auto bg-gray-950 p-2 text-[11px] leading-4 text-gray-100">{log.missing ? "" : log.content || t("preview_logs_empty_content")}</pre>
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
      <button
        className="rounded bg-terracotta-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-terracotta-700 disabled:cursor-not-allowed disabled:opacity-50"
        disabled={isPending}
        onClick={onStart}
        type="button"
      >
        {t("preview_start")}
      </button>
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
        <button
          className="rounded bg-terracotta-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-terracotta-700 disabled:cursor-not-allowed disabled:opacity-50"
          disabled={isPending}
          onClick={onStart}
          type="button"
        >
          {t("preview_restart")}
        </button>
      )
    }

    return (
      <div className="flex flex-wrap items-center gap-2">
        <a
          className="rounded bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700"
          href={env!.url ?? "#"}
          rel="noopener noreferrer"
          target="_blank"
        >
          {t("preview_open")}
        </a>
        <button
          className="rounded border border-gray-300 px-3 py-1.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
          disabled={isPending}
          onClick={onStop}
          type="button"
        >
          {t("preview_stop")}
        </button>
      </div>
    )
  }

  return null
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
            <button
              className="rounded border border-gray-300 px-4 py-1.5 text-sm text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              onClick={onKeepRunning}
              ref={cancelRef}
              type="button"
            >
              {t("preview_keep_running")}
            </button>
            <button
              className="rounded bg-red-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-red-700"
              onClick={onStop}
              type="button"
            >
              {t("preview_stop_yes")}
            </button>
          </div>
        </div>
      </section>
    </div>
  )
}
