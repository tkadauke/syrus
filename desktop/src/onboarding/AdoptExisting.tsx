import { useState } from "react"
import { FooterRow, FormError, OnboardingScreen } from "./primitives"

type AdoptExistingProps = {
  error?: string | null
  onLocateEnv: () => void
  onWipe: () => void
  onBack: () => void
}

// The encryption-key guard, in plain language. A previous install's data
// volume exists, but its .env (which holds the keys that can decrypt that
// data) isn't where this app keeps it. Never regenerate keys silently.
export function AdoptExisting({ error = null, onLocateEnv, onWipe, onBack }: AdoptExistingProps) {
  const [confirmation, setConfirmation] = useState("")
  const wipeArmed = confirmation.trim().toLowerCase() === "delete"
  const installScript =
    (window.syrusDesktop?.platform ?? "darwin") === "win32" ? "install.ps1" : "install.sh"

  return (
    <OnboardingScreen title="Found an existing Syrus installation">
      <p className="mt-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        This machine already has Syrus data from a previous install (for example from running{" "}
        <code className="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">{installScript}</code> in a checkout). That
        data is encrypted with keys stored in that install&apos;s{" "}
        <code className="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">.env</code> file. To keep your existing
        Jobs, repositories, and credentials, point us at it.
      </p>

      <div className="mt-6 rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
        <p className="text-sm font-medium text-slate-900 dark:text-slate-100">Keep my data</p>
        <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">
          Locate the original <code className="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-800">.env</code> — we
          copy it, never move it.
        </p>
        <button type="button" className="primary-button mt-3" onClick={onLocateEnv}>
          Locate .env…
        </button>
      </div>

      <div className="mt-4 rounded-xl border border-red-200 bg-white p-4 shadow-sm dark:border-red-900 dark:bg-slate-900">
        <p className="text-sm font-medium text-red-700 dark:text-red-400">Start fresh instead</p>
        <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">
          Permanently deletes the previous install&apos;s database, clone cache, and search index. Type{" "}
          <span className="font-semibold">delete</span> to enable.
        </p>
        <div className="mt-3 flex gap-2">
          <input
            type="text"
            value={confirmation}
            placeholder="delete"
            aria-label="Type delete to confirm"
            onChange={(event) => setConfirmation(event.target.value)}
            className="danger-confirm-input w-32"
          />
          <button type="button" className="danger-button" disabled={!wipeArmed} onClick={onWipe}>
            Delete all Syrus data
          </button>
        </div>
      </div>

      {error ? (
        <div className="mt-4">
          <FormError>{error}</FormError>
        </div>
      ) : null}

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onBack}>
          Back
        </button>
      </FooterRow>
    </OnboardingScreen>
  )
}
