type StartupDiagnostics = {
  mark: (milestone: string) => void
}

declare global {
  interface Window {
    SyrusStartupDiagnostics?: StartupDiagnostics
  }
}

export function markStartupMilestone(milestone: string): void {
  window.SyrusStartupDiagnostics?.mark(milestone)
}

