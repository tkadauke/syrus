type StartupDiagnostics = {
  mark: (milestone: string) => void
  fail?: (phase: StartupPhase, error: unknown, extra?: Record<string, unknown>) => void
  report?: (kind: string, message: string, extra?: Record<string, unknown>) => void
  context?: (extra?: Record<string, unknown>) => Record<string, unknown>
  snapshot?: () => StartupDiagnosticsSnapshot
  subscribe?: (listener: () => void) => () => void
  event?: (kind: string, details?: Record<string, unknown>) => void
}

export type StartupDiagnosticsSnapshot = {
  milestones: Array<{ name: string; at_ms: number }>
  assets: Array<{ path: string; bytes: number; size: number; wire_size: number; source: string; timing: Record<string, unknown> | null }>
  progress_samples: Array<{ at: number; bytes: number }>
  progress: { loaded: number; total: number; speed: number | null; secondsLeft: number | null } | null
  budget: { kind: string; bytes: number } | null
  events: Array<{ kind: string; at_ms: number; attempt?: number }>
  revision: { page: string; previous: string | null; changed: boolean }
  service_worker: { present: boolean; controlled: boolean; registration: { installing: string | null; waiting: string | null; active: string | null } | null; worker_revision: string | null; counted_requests: string[] }
  auto_retry_attempt: number
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

export function recordStartupEvent(kind: string, details?: Record<string, unknown>): void {
  window.SyrusStartupDiagnostics?.event?.(kind, details)
}
