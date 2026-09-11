import { useEffect, useRef } from "react"
import { FooterRow, OnboardingScreen, ProgressBar, Spinner } from "./primitives"
import { t } from "../i18n"

const STEP_LABELS: Record<SyrusInstallStepId, string> = {
  runtime_check: t("install_progress.runtime_check"),
  runtime_start: t("install_progress.runtime_start"),
  compose_resolve: t("install_progress.compose_resolve"),
  env_check: t("install_progress.env_check"),
  env_generate: t("install_progress.env_generate"),
  image_pull: t("install_progress.image_pull"),
  stack_up: t("install_progress.stack_up"),
  health: t("install_progress.health")
}

// Within this many pixels of the bottom edge still counts as "at the bottom"
// for autoscroll purposes — sub-line-height slack, so a reader who scrolled
// up even one line is never yanked back down.
const STICK_TO_BOTTOM_SLACK_PX = 8

type InstallProgressProps = {
  steps: SyrusInstallStep[]
  pullProgress: SyrusPullProgress | null
  logLines: string[]
  onCancel: () => void
}

const StepGlyph = ({ status }: { status: SyrusInstallStep["status"] }) => {
  if (status === "ok") {
    return <span className="text-emerald-600 dark:text-emerald-400">✓</span>
  }

  if (status === "skipped") {
    return <span className="text-slate-400 dark:text-slate-500">–</span>
  }

  if (status === "running") {
    return <Spinner />
  }

  return <span aria-hidden className="inline-block h-2 w-2 rounded-full bg-slate-300 dark:bg-slate-600" />
}

export function InstallProgress({ steps, pullProgress, logLines, onCancel }: InstallProgressProps) {
  const logRef = useRef<HTMLPreElement | null>(null)
  // Whether the user is (still) reading the newest lines. Autoscroll only
  // then — never yank someone back down while they're reading history.
  const stickToBottomRef = useRef(true)

  const handleLogScroll = () => {
    const log = logRef.current
    if (!log) {
      return
    }

    stickToBottomRef.current = log.scrollHeight - log.scrollTop - log.clientHeight <= STICK_TO_BOTTOM_SLACK_PX
  }

  useEffect(() => {
    const log = logRef.current
    if (log && stickToBottomRef.current) {
      log.scrollTop = log.scrollHeight
    }
  }, [logLines])

  return (
    <OnboardingScreen
      title={t("install_progress.title")}
      subtitle={t("install_progress.subtitle")}
    >
      <ul className="mt-6 space-y-2" aria-live="polite">
        {steps.map((step) => {
          // The image pull is the long pole: while compose reports per-layer
          // byte progress the row grows a determinate bar; without parseable
          // progress (older compose) the spinner carries the row alone.
          const showPullProgress = step.id === "image_pull" && step.status === "running" && pullProgress !== null

          return (
            <li key={step.id} className="rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm shadow-sm dark:border-slate-700 dark:bg-slate-900">
              <div className="flex items-center gap-3">
                <span className="flex w-4 justify-center">
                  <StepGlyph status={step.status} />
                </span>
                <span className={step.status === "pending" ? "text-slate-400 dark:text-slate-500" : "text-slate-800 dark:text-slate-200"}>
                  {STEP_LABELS[step.id]}
                </span>
              </div>
              {showPullProgress ? (
                // aria-live="off" overrides the list's polite region: the MB
                // counter ticks many times a minute, and role="progressbar"
                // already conveys the value without announcing every change.
                <div className="mt-2 pl-7" data-testid="pull-progress" aria-live="off">
                  <ProgressBar percent={pullProgress.percent} />
                  <p className="mt-1 text-xs tabular-nums text-slate-500 dark:text-slate-400">{pullProgress.label}</p>
                </div>
              ) : null}
            </li>
          )
        })}
      </ul>

      <details className="mt-4">
        <summary className="cursor-pointer text-xs text-slate-500 dark:text-slate-400">{t("common.show_details")}</summary>
        <pre
          ref={logRef}
          onScroll={handleLogScroll}
          className="mt-2 max-h-40 overflow-y-auto whitespace-pre-wrap break-words rounded-lg bg-slate-900 p-3 text-xs leading-relaxed text-slate-200 dark:bg-slate-950 dark:text-slate-300"
        >
          {logLines.join("\n")}
        </pre>
      </details>

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onCancel}>
          {t("common.cancel")}
        </button>
      </FooterRow>
    </OnboardingScreen>
  )
}
