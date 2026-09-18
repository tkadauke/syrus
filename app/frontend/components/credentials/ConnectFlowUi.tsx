// Small presentational primitives shared by every provider's connect-panel
// component (ClaudeConnect, CodexConnect, MuseConnect, AgyConnect, …) so the
// generic AgentProviderConnectPanel dispatch mechanism renders a consistent
// look regardless of which plugin's panel is mounted. Extracted from
// ClaudeConnect, the first of these flows.

export function StatusBox({ tone, children }: { tone: "ok" | "warning" | "error"; children: React.ReactNode }) {
  const toneClass =
    tone === "ok"
      ? "border-success-border bg-success-surface text-success-text"
      : tone === "warning"
        ? "border-warning-border bg-warning-surface text-warning-text"
        : "border-danger-border bg-danger-surface text-danger-text"
  return (
    <p className={`rounded-[var(--radius-panel)] border px-3 py-2 text-[length:var(--text-body)] ${toneClass}`} role={tone === "ok" ? "status" : "alert"}>
      {children}
    </p>
  )
}

export function Spinner({ light }: { light?: boolean }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 animate-spin ${light ? "text-on-brand" : "text-text-secondary"}`} fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}
