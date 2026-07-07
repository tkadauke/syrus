import { useEffect, useState, type CSSProperties } from "react"
import { Welcome } from "./Welcome"
import { ConnectRemote } from "./ConnectRemote"
import { RuntimeSetup } from "./RuntimeSetup"
import { AdoptExisting } from "./AdoptExisting"
import { InstallProgress } from "./InstallProgress"
import { InstallFailed } from "./InstallFailed"
import { PortConflict } from "./PortConflict"
import { FooterRow, OnboardingScreen } from "./primitives"
import syrusIconUrl from "../../assets/syrusIcon.png"

// The window uses titleBarStyle hiddenInset: the traffic lights float over
// this strip, which doubles as the drag handle.
const dragRegion = { WebkitAppRegion: "drag" } as CSSProperties

export function OnboardingApp() {
  const [state, setState] = useState<SyrusOnboardingState | null>(null)
  const [logLines, setLogLines] = useState<string[]>([])

  useEffect(() => {
    let isMounted = true

    window.syrusDesktop
      .getOnboardingState()
      .then((initial) => {
        if (isMounted) {
          setState(initial)
        }
      })
      .catch(() => {
        if (isMounted) {
          setState({ phase: "welcome" })
        }
      })

    const unsubscribeState = window.syrusDesktop.onOnboardingState((next) => {
      setState(next)
      if (next.phase === "welcome") {
        setLogLines([])
      }
    })
    const unsubscribeLog = window.syrusDesktop.onOnboardingLogLine((line) => {
      setLogLines((previous) => [...previous.slice(-499), line])
    })

    return () => {
      isMounted = false
      unsubscribeState()
      unsubscribeLog()
    }
  }, [])

  const back = () => void window.syrusDesktop.onboardingBack()

  let content = (
    <p className="text-sm text-slate-500" role="status">
      Loading…
    </p>
  )

  if (state) {
    switch (state.phase) {
      case "welcome":
        content = <Welcome onChoose={(mode) => void window.syrusDesktop.chooseOnboardingMode(mode)} />
        break
      case "connect.form":
        content = (
          <ConnectRemote
            error={state.error}
            busy={false}
            onSubmit={(url) => void window.syrusDesktop.connectRemote({ url })}
            onBack={back}
          />
        )
        break
      case "connect.checking":
        content = <ConnectRemote error={null} busy checkingUrl={state.url} onSubmit={() => {}} onBack={back} />
        break
      case "local.precheck":
        content = (
          <p className="text-sm text-slate-500" role="status">
            {window.syrusDesktop?.platform === "win32" ? "Checking this PC…" : "Checking this Mac…"}
          </p>
        )
        break
      case "local.adoptRunning":
        content = (
          <OnboardingScreen title="Syrus is already running here" subtitle={`Something is already serving Syrus at ${state.url}.`}>
            <p className="mt-4 text-sm leading-relaxed text-slate-600">
              This app didn&apos;t install it, so it can&apos;t manage starting or stopping it — but you can
              still connect to it and use everything else.
            </p>
            <FooterRow>
              <button type="button" className="secondary-button" onClick={back}>
                Back
              </button>
              <button
                type="button"
                className="primary-button"
                onClick={() => void window.syrusDesktop.adoptRunningInstance()}
              >
                Connect to it
              </button>
            </FooterRow>
          </OnboardingScreen>
        )
        break
      case "local.adoptExisting":
        content = (
          <AdoptExisting
            error={state.error}
            onLocateEnv={() => void window.syrusDesktop.locateEnvFile()}
            onWipe={() => void window.syrusDesktop.wipeLocalData()}
            onBack={back}
          />
        )
        break
      case "local.runtimeMissing":
        content = (
          <RuntimeSetup
            mode="missing"
            polling={state.polling}
            wslMissing={state.wslMissing}
            onInstallWsl={() => void window.syrusDesktop.installWsl()}
            onDownload={() => void window.syrusDesktop.openOrbStackDownload()}
            onRetry={() => void window.syrusDesktop.retryOnboarding()}
            onBack={back}
          />
        )
        break
      case "local.runtimeStarting":
        content = (
          <RuntimeSetup
            mode="starting"
            polling
            needsAttention={state.needsAttention}
            onOpenRuntime={() => void window.syrusDesktop.openRuntimeApp()}
            onDownload={() => {}}
            onRetry={() => {}}
            onBack={back}
          />
        )
        break
      case "local.portConflict":
        content = (
          <PortConflict
            port={state.port}
            onContinue={(port) => void window.syrusDesktop.startInstall(port)}
            onBack={back}
          />
        )
        break
      case "local.installing":
        content = (
          <InstallProgress
            steps={state.steps}
            logLines={logLines}
            onCancel={() => void window.syrusDesktop.cancelInstall()}
          />
        )
        break
      case "local.failed":
        content = (
          <InstallFailed
            code={state.code}
            step={state.step}
            message={state.message}
            logTail={state.logTail}
            onRetry={() => void window.syrusDesktop.retryOnboarding()}
            onBack={back}
          />
        )
        break
      case "done":
        content = (
          <section className="w-full max-w-md text-center">
            <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-emerald-100">
              <span aria-hidden className="text-2xl text-emerald-600">
                ✓
              </span>
            </div>
            <h1 className="mt-4 text-xl font-semibold">
              {state.mode === "local" ? "Syrus is installed and running" : "Connected to Syrus"}
            </h1>
            <p className="mt-2 text-sm text-slate-600">{state.url}</p>
            <button
              type="button"
              className="primary-button mt-6"
              onClick={() => void window.syrusDesktop.finishOnboarding()}
            >
              Open Syrus
            </button>
          </section>
        )
        break
    }
  }

  return (
    <div className="flex h-screen flex-col bg-slate-50 text-slate-900 antialiased">
      <header className="flex h-12 shrink-0 items-center justify-center" style={dragRegion}>
        <img src={syrusIconUrl} alt="" className="h-5 w-5 opacity-60" />
      </header>
      <main className="flex min-h-0 flex-1 overflow-y-auto px-10 py-6">
        {/* my-auto (not items-center on the parent): centers short content
            vertically, but lets tall content scroll from the top instead of
            clipping it above the viewport. */}
        <div className="my-auto flex w-full justify-center pb-4" data-testid="onboarding-content">
          {content}
        </div>
      </main>
    </div>
  )
}
