import { OnboardingScreen } from "./primitives"

type WelcomeProps = {
  onChoose: (mode: "local" | "remote") => void
}

export function Welcome({ onChoose }: WelcomeProps) {
  const platform = window.syrusDesktop?.platform ?? "darwin"
  const isWindows = platform === "win32"

  return (
    <OnboardingScreen
      title="Welcome to Syrus"
      subtitle="Syrus turns GitHub issues into reviewed pull requests. Where should it run?"
      width="xl"
    >
      <div className="mt-8 grid grid-cols-2 gap-4 text-left">
        <button
          type="button"
          onClick={() => onChoose("local")}
          className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm transition hover:border-terracotta-400 hover:shadow dark:border-slate-700 dark:bg-slate-900 dark:hover:border-terracotta-500"
        >
          <span className="block text-base font-semibold text-slate-900 dark:text-slate-100">
            {isWindows ? "Install on this PC" : "Install on this Mac"}
          </span>
          <span className="mt-2 block text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {isWindows
              ? "Runs Syrus locally on Docker Desktop. Everything stays on your machine — this app sets it all up."
              : "Runs Syrus locally in Docker. Everything stays on your machine — this app sets it all up."}
          </span>
        </button>

        <button
          type="button"
          onClick={() => onChoose("remote")}
          className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm transition hover:border-terracotta-400 hover:shadow dark:border-slate-700 dark:bg-slate-900 dark:hover:border-terracotta-500"
        >
          <span className="block text-base font-semibold text-slate-900 dark:text-slate-100">Connect to existing Syrus</span>
          <span className="mt-2 block text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            Your team already runs Syrus somewhere? Point this app at its address.
          </span>
        </button>
      </div>
    </OnboardingScreen>
  )
}
