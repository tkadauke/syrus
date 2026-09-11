import { FooterRow, OnboardingScreen, Spinner } from "./primitives"
import { t } from "../i18n"

type RuntimeSetupProps = {
  mode: "missing" | "starting" | "installing"
  polling: boolean
  // Windows only: WSL 2 itself is absent, so Docker Desktop can't run yet.
  wslMissing?: boolean
  // Starting mode only: the daemon has been quiet long enough that the
  // runtime app is almost certainly waiting on the USER (Docker Desktop's
  // first-run service agreement / optional sign-in), not just booting.
  needsAttention?: boolean
  // Installing mode: which stage the unattended Docker Desktop install is in,
  // and the download percentage (null = indeterminate).
  installStep?: "downloading" | "installing"
  installPercent?: number | null
  // Missing mode: the last auto-install attempt failed — offer retry/manual.
  installError?: string | null
  onInstallWsl?: () => void
  onInstallRuntime?: () => void
  onOpenRuntime?: () => void
  onDownload: () => void
  onRetry: () => void
  onBack: () => void
}

// Guided Docker-runtime acquisition: no Homebrew, no PowerShell, no
// terminal. We point the user at the recommended runtime's installer and
// poll until the daemon answers. Per-platform: OrbStack on macOS; Docker
// Desktop on Windows, with a one-click WSL 2 install first when WSL is
// missing (Docker Desktop's own installer punts that to a manual step).
export function RuntimeSetup({ mode, polling, wslMissing = false, needsAttention = false, installStep = "downloading", installPercent = null, installError = null, onInstallWsl, onInstallRuntime, onOpenRuntime, onDownload, onRetry, onBack }: RuntimeSetupProps) {
  const isWindows = (window.syrusDesktop?.platform ?? "darwin") === "win32"
  const runtimeName = isWindows ? "Docker Desktop" : "OrbStack"

  // Unattended Docker Desktop install in progress: Syrus downloaded the
  // official installer and is running it with the license pre-accepted — the
  // user has nothing to click, so the screen just narrates.
  if (mode === "installing") {
    return (
      <OnboardingScreen
        title={t("runtime.installing_title")}
        subtitle={t("runtime.installing_subtitle")}
      >
        {installStep === "downloading" ? (
          <div className="mt-5" data-testid="runtime-install-progress">
            <p className="text-sm text-slate-600 dark:text-slate-400">
              {t("runtime.downloading", { percent: installPercent !== null ? ` -- ${installPercent}%` : "..." })}
            </p>
            <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-slate-200 dark:bg-slate-700">
              <div
                className="h-full rounded-full bg-terracotta-600 transition-all"
                style={{ width: `${installPercent ?? 8}%` }}
              />
            </div>
          </div>
        ) : (
          <p className="mt-5 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400" role="status">
            <Spinner />
            {t("runtime.running_installer")}
          </p>
        )}
        <FooterRow>
          <button type="button" className="secondary-button" onClick={onBack}>
            {t("common.back")}
          </button>
        </FooterRow>
      </OnboardingScreen>
    )
  }

  if (mode === "starting") {
    // The daemon has been quiet long enough that the runtime app is waiting
    // on the user, not booting — the field failure was Syrus saying
    // "Starting…" forever while Docker Desktop sat behind it with a license
    // dialog. Say exactly what to click, and offer to bring the window up.
    if (needsAttention) {
      return (
        <OnboardingScreen
          title={t("runtime.needs_setup_title", { runtime: runtimeName })}
          subtitle={t("runtime.needs_setup_subtitle")}
        >
          <div className="mt-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900" data-testid="runtime-attention">
            <p className="text-sm leading-relaxed text-slate-600 dark:text-slate-400">
              {isWindows ? (
                <>
                  {t("runtime.needs_windows")}
                </>
              ) : (
                <>
                  {t("runtime.needs_other", { runtime: runtimeName })}
                </>
              )}
            </p>
            <button type="button" className="primary-button mt-3" onClick={onOpenRuntime}>
              {t("runtime.open", { runtime: runtimeName })}
            </button>
          </div>
          <p className="mt-4 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400" role="status">
            <Spinner />
            {t("runtime.wait_engine")}
          </p>
          <FooterRow>
            <button type="button" className="secondary-button" onClick={onBack}>
              {t("common.back")}
            </button>
          </FooterRow>
        </OnboardingScreen>
      )
    }

    return (
      <OnboardingScreen
        title={t("runtime.starting_title")}
        subtitle={t("runtime.starting_subtitle")}
      >
        <p className="mt-4 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400" role="status">
          <Spinner />
          {t("runtime.wait_docker")}
        </p>
        <FooterRow>
          <button type="button" className="secondary-button" onClick={onBack}>
            {t("common.back")}
          </button>
        </FooterRow>
      </OnboardingScreen>
    )
  }

  return (
    <OnboardingScreen
      title={t("runtime.missing_title")}
      subtitle={t("runtime.missing_subtitle")}
    >
      <p className="mt-4 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
        {isWindows ? (
          <>
            {t("runtime.recommend_windows")}
          </>
        ) : (
          <>
            {t("runtime.recommend_mac")}
          </>
        )}
      </p>

      {isWindows && wslMissing ? (
        <div className="mt-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900" data-testid="wsl-step">
          <p className="text-sm font-medium text-slate-900 dark:text-slate-100">{t("runtime.wsl_title")}</p>
          <p className="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {t("runtime.wsl_body")}
          </p>
          <button type="button" className="primary-button mt-3" onClick={onInstallWsl}>
            {t("runtime.install_wsl")}
          </button>
        </div>
      ) : null}

      {isWindows ? (
        <div className="mt-5 rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900" data-testid="runtime-auto-install">
          <p className="text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {t("runtime.auto_install_body")}
          </p>
          {installError ? (
            <p className="mt-2 text-sm text-red-600 dark:text-red-400" data-testid="runtime-install-error">
              {installError}
            </p>
          ) : null}
          <button type="button" className="primary-button mt-3" onClick={onInstallRuntime} disabled={wslMissing}>
            {t("runtime.install_docker")}
          </button>
          {wslMissing ? (
            <p className="mt-2 text-xs text-slate-500 dark:text-slate-400">{t("runtime.install_wsl_first")}</p>
          ) : null}
        </div>
      ) : (
        <ol className="mt-5 list-decimal space-y-2 pl-5 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          <li>{t("runtime.download_step", { runtime: runtimeName })}</li>
          <li>{t("runtime.open_step")}</li>
          <li>{t("runtime.return_step")}</li>
        </ol>
      )}

      {polling ? (
        <p className="mt-5 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400" role="status">
          <Spinner />
          {t("runtime.wait_available")}
        </p>
      ) : null}

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onBack}>
          {t("common.back")}
        </button>
        <div className="flex items-center gap-2">
          {polling ? (
            <button type="button" className="secondary-button" onClick={onRetry}>
              {t("runtime.check_now")}
            </button>
          ) : null}
          {isWindows ? (
            <button type="button" className="text-sm text-slate-500 underline hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200" onClick={onDownload}>
              {t("runtime.download_manual")}
            </button>
          ) : (
            <button type="button" className="primary-button" onClick={onDownload}>
              {t("runtime.download", { runtime: runtimeName })}
            </button>
          )}
        </div>
      </FooterRow>
    </OnboardingScreen>
  )
}
