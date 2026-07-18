import { useEffect, useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { fetchBootstrap } from "../api/bootstrap"
import { CloseIcon } from "./CloseIcon"
import { GithubAppPanel } from "./GithubAppPanel"
import { GithubTokenStep } from "./credentials/GithubTokenStep"
import { useT } from "../hooks/useT"
import { useBackendOutage } from "../hooks/useBackendUpdate"

// The GitHub onboarding step requires BOTH credentials, set up in order:
// first a personal access token, then the GitHub App.
export function GithubTokenModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const { t } = useT("settings")
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const isAdmin = !!bootstrap.data?.current_user?.admin
  const credStatus = bootstrap.data?.setup_status?.credential_status
  // While the desktop shell's backend update has the containers down,
  // credential status can't be read — a failed bootstrap here would present
  // the "no token yet" step to a user whose token sits safely in the DB. Say
  // what's actually happening instead of defaulting to "unconfigured".
  // (During the image pull the old backend still serves — no gate.)
  const backendOutage = useBackendOutage()

  // Local optimistic flag so the flow advances to the App step immediately
  // after the token saves, before the bootstrap refetch lands.
  const [patSaved, setPatSaved] = useState(false)
  const patDone = !!credStatus?.github_pat || patSaved
  const appDone = !!credStatus?.github_app // for the stepper only
  // First the token, then the GitHub App step (which itself does create →
  // install, owned by GithubAppPanel).
  const phase: "pat" | "app" = patDone ? "app" : "pat"

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="github-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-5 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="github-title">{t('github_token.title')}</h2>
              {phase === "pat" ? (
                <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
                  {t('github_token.description')}
                </p>
              ) : null}
            </div>
            <button
              aria-label={t('github_token.close')}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          {backendOutage ? (
            <Box tone="muted">{t('backend_updating')}</Box>
          ) : (
            <>
              <Stepper patDone={patDone} appDone={appDone} active={phase} />

              {phase === "pat" ? (
                <GithubTokenStep onSaved={() => setPatSaved(true)} />
              ) : isAdmin ? (
                // Create → install the GitHub App, owned by the panel.
                <GithubAppPanel onClose={onClose} onSaved={onSaved} />
              ) : (
                <Box tone="muted">
                  {t('github_token.admin_required')}
                </Box>
              )}
            </>
          )}
        </div>
      </section>
    </div>
  )
}

function Stepper({ patDone, appDone, active }: { patDone: boolean; appDone: boolean; active: "pat" | "app" }) {
  const { t } = useT("settings")
  const steps = [
    { key: "pat", label: t('github_token.step_pat_label'), done: patDone },
    { key: "app", label: t('github_token.step_app_label'), done: appDone }
  ]
  return (
    <ol className="flex items-center gap-2 text-xs font-medium">
      {steps.map((step, index) => {
        const current = active === step.key
        const tone = step.done
          ? "bg-green-100 text-green-700 dark:bg-green-950/60 dark:text-green-300"
          : current
            ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-300"
            : "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"
        return (
          <li className="flex items-center gap-2" key={step.key}>
            <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 ${tone}`}>
              <span>{step.done ? "✓" : index + 1}</span> {step.label}
            </span>
            {index < steps.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
          </li>
        )
      })}
    </ol>
  )
}

function Box({ tone, children }: { tone: "ok" | "muted" | "error"; children: React.ReactNode }) {
  const toneClass = tone === "ok" ? "banner-success" : tone === "error" ? "banner-error" : "banner-muted"
  return <p className={`${toneClass} px-3 py-2 text-sm`} role={tone === "error" ? "alert" : tone === "ok" ? "status" : undefined}>{children}</p>
}
