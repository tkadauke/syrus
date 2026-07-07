import { FooterRow, OnboardingScreen, Spinner } from "./primitives"

type RuntimeSetupProps = {
  mode: "missing" | "starting"
  polling: boolean
  // Windows only: WSL 2 itself is absent, so Docker Desktop can't run yet.
  wslMissing?: boolean
  // Starting mode only: the daemon has been quiet long enough that the
  // runtime app is almost certainly waiting on the USER (Docker Desktop's
  // first-run service agreement / optional sign-in), not just booting.
  needsAttention?: boolean
  onInstallWsl?: () => void
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
export function RuntimeSetup({ mode, polling, wslMissing = false, needsAttention = false, onInstallWsl, onOpenRuntime, onDownload, onRetry, onBack }: RuntimeSetupProps) {
  const isWindows = (window.syrusDesktop?.platform ?? "darwin") === "win32"
  const runtimeName = isWindows ? "Docker Desktop" : "OrbStack"

  if (mode === "starting") {
    // The daemon has been quiet long enough that the runtime app is waiting
    // on the user, not booting — the field failure was Syrus saying
    // "Starting…" forever while Docker Desktop sat behind it with a license
    // dialog. Say exactly what to click, and offer to bring the window up.
    if (needsAttention) {
      return (
        <OnboardingScreen
          title={`${runtimeName} needs you to finish its setup`}
          subtitle="Syrus started your Docker runtime, but its engine hasn't come up — it's waiting for you."
        >
          <div className="mt-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm" data-testid="runtime-attention">
            <p className="text-sm leading-relaxed text-slate-600">
              {isWindows ? (
                <>
                  Open the <span className="font-medium text-slate-900">Docker Desktop</span> window and{" "}
                  <span className="font-medium text-slate-900">Accept</span> its service agreement. Signing in is
                  optional — you can skip it. Syrus continues automatically the moment the engine is running.
                </>
              ) : (
                <>
                  Open the <span className="font-medium text-slate-900">{runtimeName}</span> window and finish
                  its first-run setup. Syrus continues automatically the moment the engine is running.
                </>
              )}
            </p>
            <button type="button" className="primary-button mt-3" onClick={onOpenRuntime}>
              Open {runtimeName}
            </button>
          </div>
          <p className="mt-4 flex items-center justify-center gap-2 text-sm text-slate-500" role="status">
            <Spinner />
            Waiting for the Docker engine…
          </p>
          <FooterRow>
            <button type="button" className="secondary-button" onClick={onBack}>
              Back
            </button>
          </FooterRow>
        </OnboardingScreen>
      )
    }

    return (
      <OnboardingScreen
        title="Starting your Docker runtime…"
        subtitle="The first launch can take a moment and may ask for a one-time permission — accept it if it does."
      >
        <p className="mt-4 flex items-center justify-center gap-2 text-sm text-slate-500" role="status">
          <Spinner />
          Waiting for Docker…
        </p>
        <FooterRow>
          <button type="button" className="secondary-button" onClick={onBack}>
            Back
          </button>
        </FooterRow>
      </OnboardingScreen>
    )
  }

  return (
    <OnboardingScreen
      title="One thing first: a Docker runtime"
      subtitle="Syrus runs in containers, which needs a Docker runtime."
    >
      <p className="mt-4 text-sm leading-relaxed text-slate-600">
        {isWindows ? (
          <>
            We recommend <span className="font-medium text-slate-900">Docker Desktop</span>, which runs on
            WSL&nbsp;2.
          </>
        ) : (
          <>
            We recommend <span className="font-medium text-slate-900">OrbStack</span> — it&apos;s fast,
            lightweight, and free for personal use. Docker Desktop works too.
          </>
        )}
      </p>

      {isWindows && wslMissing ? (
        <div className="mt-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm" data-testid="wsl-step">
          <p className="text-sm font-medium text-slate-900">First: install WSL 2</p>
          <p className="mt-1 text-sm leading-relaxed text-slate-600">
            This PC doesn&apos;t have WSL&nbsp;2 yet. Click below and accept the Windows permission prompt —
            no terminal needed. Windows may ask to restart afterwards; after the restart, reopen Syrus and it
            picks up right here.
          </p>
          <button type="button" className="primary-button mt-3" onClick={onInstallWsl}>
            Install WSL 2
          </button>
        </div>
      ) : null}

      <ol className="mt-5 list-decimal space-y-2 pl-5 text-sm leading-relaxed text-slate-600">
        <li>
          {isWindows
            ? `Download ${runtimeName} and run its installer. If it asks to restart Windows, restart — then reopen Syrus and it picks up right here.`
            : `Download ${runtimeName} and drag it into Applications.`}
        </li>
        <li>Open it once and finish its short setup.</li>
        <li>Come back here — we&apos;ll pick things up automatically.</li>
      </ol>

      {polling ? (
        <p className="mt-5 flex items-center justify-center gap-2 text-sm text-slate-500" role="status">
          <Spinner />
          Waiting for Docker to become available…
        </p>
      ) : null}

      <FooterRow>
        <button type="button" className="secondary-button" onClick={onBack}>
          Back
        </button>
        <div className="flex gap-2">
          {polling ? (
            <button type="button" className="secondary-button" onClick={onRetry}>
              Check again now
            </button>
          ) : null}
          <button type="button" className="primary-button" onClick={onDownload}>
            Download {runtimeName}
          </button>
        </div>
      </FooterRow>
    </OnboardingScreen>
  )
}
