type StartupDiagnostics = {
  mark: (milestone: string) => void
  report?: (kind: string, message: string, extra?: Record<string, unknown>) => void
  context?: (extra?: Record<string, unknown>) => Record<string, unknown>
}

declare global {
  interface Window {
    SyrusStartupDiagnostics?: StartupDiagnostics
    __syrusReactFirstRender?: boolean
  }
}

export function markStartupMilestone(milestone: string): void {
  window.SyrusStartupDiagnostics?.mark(milestone)
}
