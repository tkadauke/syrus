import { useState } from "react"
import { useQuery } from "@tanstack/react-query"
import { fetchBootstrap } from "../api/bootstrap"
import { CloseIcon } from "./CloseIcon"
import { GithubAppPanel } from "./GithubAppPanel"
import { GithubTokenStep } from "./credentials/GithubTokenStep"
import { Modal } from "./Modal"
import { Stepper } from "./Stepper"
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

  return (
    <Modal
      className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
      labelledBy="github-title"
      onClose={onClose}
      open
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
            <Stepper
              active={phase}
              steps={[
                { key: "pat", label: t('github_token.step_pat_label'), done: patDone },
                { key: "app", label: t('github_token.step_app_label'), done: appDone }
              ]}
            />

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
    </Modal>
  )
}

function Box({ tone, children }: { tone: "ok" | "muted" | "error"; children: React.ReactNode }) {
  const toneClass = tone === "ok"
    ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/40 dark:text-green-300"
    : tone === "error"
      ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
      : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800/50 dark:text-gray-400"
  return <p className={`rounded border px-3 py-2 text-sm ${toneClass}`} role={tone === "error" ? "alert" : tone === "ok" ? "status" : undefined}>{children}</p>
}
