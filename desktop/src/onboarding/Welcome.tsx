import { OnboardingScreen } from "./primitives"
import { t } from "../i18n"

type WelcomeProps = {
  onChoose: (mode: "local" | "remote") => void
}

export function Welcome({ onChoose }: WelcomeProps) {
  const platform = window.syrusDesktop?.platform ?? "darwin"
  const isWindows = platform === "win32"

  return (
    <OnboardingScreen
      title={t("onboarding.welcome.title")}
      subtitle={t("onboarding.welcome.subtitle")}
      width="xl"
    >
      <div className="mt-8 grid grid-cols-2 gap-4 text-left">
        <button
          type="button"
          onClick={() => onChoose("local")}
          className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm transition hover:border-terracotta-400 hover:shadow dark:border-slate-700 dark:bg-slate-900 dark:hover:border-terracotta-500"
        >
          <span className="block text-base font-semibold text-slate-900 dark:text-slate-100">
            {isWindows ? t("onboarding.welcome.install_pc") : t("onboarding.welcome.install_mac")}
          </span>
          <span className="mt-2 block text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {isWindows
              ? t("onboarding.welcome.local_windows")
              : t("onboarding.welcome.local_mac")}
          </span>
        </button>

        <button
          type="button"
          onClick={() => onChoose("remote")}
          className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm transition hover:border-terracotta-400 hover:shadow dark:border-slate-700 dark:bg-slate-900 dark:hover:border-terracotta-500"
        >
          <span className="block text-base font-semibold text-slate-900 dark:text-slate-100">{t("onboarding.welcome.remote")}</span>
          <span className="mt-2 block text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {t("onboarding.welcome.remote_hint")}
          </span>
        </button>
      </div>
    </OnboardingScreen>
  )
}
