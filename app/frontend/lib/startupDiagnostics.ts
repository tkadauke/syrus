type StartupDiagnostics = {
  mark: (milestone: string) => void
  fail?: (phase: StartupPhase, error: unknown, extra?: Record<string, unknown>) => void
  report?: (kind: string, message: string, extra?: Record<string, unknown>) => void
  context?: (extra?: Record<string, unknown>) => Record<string, unknown>
}

export type StartupPhase = "bundle_evaluation" | "root_mount" | "bootstrap_fetch" | "route_initialization"

declare global {
  interface Window {
    SyrusStartupDiagnostics?: StartupDiagnostics
    __syrusReactFirstRender?: boolean
    __syrusStartupFallbackTimer?: number | null
  }
}

export function markStartupMilestone(milestone: string): void {
  window.SyrusStartupDiagnostics?.mark(milestone)
}

export function reportStartupFailure(phase: StartupPhase, error: unknown, extra?: Record<string, unknown>): void {
  window.SyrusStartupDiagnostics?.fail?.(phase, error, extra)
}
