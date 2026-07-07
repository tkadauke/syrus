import { FooterRow, OnboardingScreen, Spinner } from "./primitives"

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
        title="Installing Docker Desktop…"
        subtitle="Syrus is setting up your Docker runtime — no clicks needed. The service agreement is accepted for you."
      >
        {installStep === "downloading" ? (
          <div className="mt-5" data-testid="runtime-install-progress">
            <p className="text-sm text-slate-600">
              Downloading the Docker Desktop installer{installPercent !== null ? ` — ${installPercent}%` : "…"}
            </p>
            <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-slate-200">
              <div
                className="h-full rounded-full bg-terracotta-600 transition-all"
                style={{ width: `${installPercent ?? 8}%` }}
              />
            </div>
          </div>
        ) : (
          <p className="mt-5 flex items-center justify-center gap-2 text-sm text-slate-500" role="status">
            <Spinner />
            Running the installer — the first install can take a few minutes…
          </p>
        )}
        <FooterRow>
          <button type="button" className="secondary-button" onClick={onBack}>
            Back
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

      {isWindows ? (
        <div className="mt-5 rounded-xl border border-slate-200 bg-white p-4 shadow-sm" data-testid="runtime-auto-install">
          <p className="text-sm leading-relaxed text-slate-600">
            Syrus can <span className="font-medium text-slate-900">install Docker Desktop for you</span> — it
            downloads the official installer and runs it silently. No admin permission needed, and the service
            agreement is accepted for you, so there&apos;s nothing to click afterwards. If Windows restarts,
            reopen isn&apos;t needed either: Syrus relaunches after you log back in and picks up right here.
          </p>
          {installError ? (
            <p className="mt-2 text-sm text-red-600" data-testid="runtime-install-error">
              {installError}
            </p>
          ) : null}
          <button type="button" className="primary-button mt-3" onClick={onInstallRuntime} disabled={wslMissing}>
            Install Docker Desktop
          </button>
          {wslMissing ? (
            <p className="mt-2 text-xs text-slate-500">Install WSL 2 above first — Docker Desktop runs on it.</p>
          ) : null}
        </div>
      ) : (
        <ol className="mt-5 list-decimal space-y-2 pl-5 text-sm leading-relaxed text-slate-600">
          <li>{`Download ${runtimeName} and drag it into Applications.`}</li>
          <li>Open it once and finish its short setup.</li>
          <li>Come back here — we&apos;ll pick things up automatically.</li>
        </ol>
      )}

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
        <div className="flex items-center gap-2">
          {polling ? (
            <button type="button" className="secondary-button" onClick={onRetry}>
              Check again now
            </button>
          ) : null}
          {isWindows ? (
            <button type="button" className="text-sm text-slate-500 underline hover:text-slate-700" onClick={onDownload}>
              download manually instead
            </button>
          ) : (
            <button type="button" className="primary-button" onClick={onDownload}>
              Download {runtimeName}
            </button>
          )}
        </div>
      </FooterRow>
    </OnboardingScreen>
  )
}
