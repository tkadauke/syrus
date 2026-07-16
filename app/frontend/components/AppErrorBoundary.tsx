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

function AppErrorFallback({ error, componentStack, fingerprint: fp, alreadyReported }: FallbackProps) {
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
      setJobId(result.job_id)
      setReportState("success")
    } catch {
      setReportState("error")
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-50" role="alert">
      <div className="w-full max-w-lg rounded-lg border border-gray-200 bg-white p-8 shadow-sm">
        <h1 className="text-xl font-semibold text-gray-900">{t("app_name")}</h1>
        <p className="mt-1 text-sm text-gray-600">{t("errorBoundary.appCrashHeading")}</p>
        <code className="mt-4 block break-all rounded border border-red-100 bg-red-50 p-3 text-xs text-red-700">
          {error.message}
        </code>
        <div className="mt-4 flex flex-wrap items-center gap-2">
          <button
            className="rounded border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50"
            onClick={() => window.location.reload()}
            type="button"
          >
            {t("route_error.reload_page")}
          </button>
          {reportState === "success" ? (
            <span className="text-sm text-gray-500">
              {jobId != null ? t("route_error.reported_as", { job_id: jobId }) : t("route_error.already_reported")}
            </span>
          ) : reportState === "error" ? (
            <span className="text-sm text-red-600">{t("route_error.report_failed")}</span>
          ) : alreadyReported ? (
            <span className="text-sm text-gray-500">{t("route_error.already_reported")}</span>
          ) : (
            <button
              className="rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-500 disabled:opacity-60"
              disabled={reportState === "loading"}
              onClick={() => void sendReport()}
              type="button"
            >
              {t("route_error.send_report")}
            </button>
          )}
        </div>
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

export class AppErrorBoundary extends Component<{ children: ReactNode }, BoundaryState> {
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
        <AppErrorFallback
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
