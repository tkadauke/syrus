import { FooterRow, LogTail, OnboardingScreen } from "./primitives"
import { t } from "../i18n"

type InstallFailedProps = {
  code: number
  step: string | null
  message: string
  logTail: string[]
  onRetry: () => void
  onBack: () => void
}

const FRIENDLY_MESSAGES: Record<number, string> = {
  12: t("install_failed.code_12"),
  30: t("install_failed.code_30"),
  31: t("install_failed.code_31"),
  32: t("install_failed.code_32"),
  40: t("install_failed.code_40"),
  41: t("install_failed.code_41")
}

export function InstallFailed({ code, step, message, logTail, onRetry, onBack }: InstallFailedProps) {
  const friendly = FRIENDLY_MESSAGES[code]

  return (
    <OnboardingScreen title={t("install_failed.title")} titleTone="danger">
      <p className="mt-3 text-sm leading-relaxed text-slate-700 dark:text-slate-300">{friendly ?? message}</p>
      {friendly ? <p className="mt-2 text-xs text-slate-500 dark:text-slate-400">{message}</p> : null}
      {step ? (
        <p className="mt-1 text-xs text-slate-400 dark:text-slate-500">
          {t("install_failed.failed_during", { step, code })}
        </p>
      ) : null}

      <LogTail lines={logTail} label={t("install_failed.show_log_tail")} />

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onBack}>
          {t("common.back")}
        </button>
        <button type="button" className="primary-button" onClick={onRetry}>
          {t("common.try_again")}
        </button>
      </FooterRow>
    </OnboardingScreen>
  )
}
