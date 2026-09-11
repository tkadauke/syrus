import { useState } from "react"
import { FooterRow, FormError, OnboardingScreen } from "./primitives"
import { t } from "../i18n"

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
    <OnboardingScreen title={t("adopt_existing.title")}>
      <p className="mt-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {t("adopt_existing.body", { script: installScript })}
      </p>

      <div className="mt-6 rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
        <p className="text-sm font-medium text-slate-900 dark:text-slate-100">{t("adopt_existing.keep")}</p>
        <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {t("adopt_existing.keep_hint")}
        </p>
        <button type="button" className="primary-button mt-3" onClick={onLocateEnv}>
          {t("adopt_existing.locate")}
        </button>
      </div>

      <div className="mt-4 rounded-xl border border-red-200 bg-white p-4 shadow-sm dark:border-red-900 dark:bg-slate-900">
        <p className="text-sm font-medium text-red-700 dark:text-red-400">{t("adopt_existing.fresh")}</p>
        <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {t("adopt_existing.fresh_hint", { word: t("adopt_existing.confirm_word") })}
        </p>
        <div className="mt-3 flex gap-2">
          <input
            type="text"
            value={confirmation}
            placeholder={t("adopt_existing.confirm_word")}
            aria-label={t("adopt_existing.confirm_label")}
            onChange={(event) => setConfirmation(event.target.value)}
            className="danger-confirm-input w-32"
          />
          <button type="button" className="danger-button" disabled={!wipeArmed} onClick={onWipe}>
            {t("adopt_existing.delete_all")}
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
          {t("common.back")}
        </button>
      </FooterRow>
    </OnboardingScreen>
  )
}
