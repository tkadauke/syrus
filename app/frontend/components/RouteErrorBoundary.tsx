import { Component, useState, type ErrorInfo, type ReactNode } from "react"
import { createBugReport } from "../api/bugReports"
import { useT } from "../hooks/useT"

const STORAGE_KEY = "syrus_reported_errors"

function computeFingerprint(error: Error): string {
  try {
    return btoa(error.message + "\n" + (error.stack ?? "")).slice(0, 64)
  } catch {
    try {
      return btoa(encodeURIComponent(error.message)).slice(0, 64)
    } catch {
      return "unknown"
    }
  }
}

function readReportedFingerprints(): string[] {
  try {
    return JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "[]") as string[]
  } catch {
    return []
  }
}

function markFingerprint(fp: string): void {
  try {
    const current = readReportedFingerprints()
    if (!current.includes(fp)) {
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify([...current, fp]))
    }
  } catch {
    // sessionStorage unavailable
  }
}

type FallbackProps = {
  error: Error
  componentStack: string
  fingerprint: string
  alreadyReported: boolean
}

function RouteErrorFallback({ error, componentStack, fingerprint: fp, alreadyReported }: FallbackProps) {
  const { t } = useT("common")
  const [reportState, setReportState] = useState<"idle" | "loading" | "success" | "error">("idle")
  const [jobId, setJobId] = useState<number | null>(null)

  async function sendReport() {
    setReportState("loading")
    try {
      const title = ("Frontend error: " + error.message).slice(0, 200)
      const description = `${componentStack}\n\n${error.stack ?? ""}`
      const result = await createBugReport({ title, description })
      markFingerprint(fp)
      setJobId(result.job_id ?? null)
      setReportState("success")
    } catch {
      setReportState("error")
    }
  }

  return (
    <div
      className="m-4 rounded border border-red-200 bg-red-50 p-3 text-sm dark:border-red-800 dark:bg-red-950/40"
      role="alert"
    >
      <p className="font-medium text-red-800 dark:text-red-200">{t("route_error.heading")}</p>
      <code className="mt-2 block break-all text-xs text-red-700 dark:text-red-300">{error.message}</code>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button
          className="rounded border border-gray-300 px-2.5 py-1 text-xs text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
          onClick={() => window.history.back()}
          type="button"
        >
          {t("route_error.go_back")}
        </button>
        <button
          className="rounded border border-gray-300 px-2.5 py-1 text-xs text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
          onClick={() => window.location.reload()}
          type="button"
        >
          {t("route_error.reload_page")}
        </button>
        {reportState === "success" ? (
          <span className="text-xs text-gray-500 dark:text-gray-400">
            {jobId != null ? t("route_error.reported_as", { job_id: jobId }) : t("route_error.already_reported")}
          </span>
        ) : reportState === "error" ? (
          <span className="text-xs text-red-600 dark:text-red-400">{t("route_error.report_failed")}</span>
        ) : alreadyReported ? (
          <span className="text-xs text-gray-500 dark:text-gray-400">{t("route_error.already_reported")}</span>
        ) : (
          <button
            className="rounded bg-terracotta-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-terracotta-500 disabled:opacity-60"
            disabled={reportState === "loading"}
            onClick={() => void sendReport()}
            type="button"
          >
            {t("route_error.send_report")}
          </button>
        )}
      </div>
    </div>
  )
}

type BoundaryState =
  | { hasError: false }
  | {
      hasError: true
      error: Error
      componentStack: string
      fingerprint: string
      alreadyReported: boolean
    }

export class RouteErrorBoundary extends Component<{ children: ReactNode }, BoundaryState> {
  constructor(props: { children: ReactNode }) {
    super(props)
    this.state = { hasError: false }
  }

  static getDerivedStateFromError(error: Error): BoundaryState {
    const fp = computeFingerprint(error)
    return {
      hasError: true,
      error,
      componentStack: "",
      fingerprint: fp,
      alreadyReported: readReportedFingerprints().includes(fp)
    }
  }

  componentDidCatch(_error: Error, info: ErrorInfo) {
    this.setState((prev) => {
      if (!prev.hasError) return prev
      return { ...prev, componentStack: info.componentStack ?? "" }
    })
  }

  render() {
    if (this.state.hasError) {
      return (
        <RouteErrorFallback
          alreadyReported={this.state.alreadyReported}
          componentStack={this.state.componentStack}
          error={this.state.error}
          fingerprint={this.state.fingerprint}
        />
      )
    }

    return this.props.children
  }
}
