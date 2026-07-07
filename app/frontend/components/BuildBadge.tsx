import { Fragment } from "react"
import { desktopBuildSha, desktopBuiltAt } from "../lib/desktopShell"

// "app 0.1.2 — built Jul 7, 2026, 2:32 PM". No tooltip when the timestamp
// is absent (dev backends without SYRUS_BUILT_AT, older desktop shells) or
// unparseable — a broken hover is worse than none.
function builtTooltip(label: string, timestamp: string | null | undefined): string | undefined {
  if (!timestamp) return undefined
  const date = new Date(timestamp)
  if (Number.isNaN(date.getTime())) return undefined

  const formatted = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)
  return `${label} — built ${formatted}`
}

// Tiny fixed corner note identifying exactly which builds are running —
// indispensable when juggling test DMGs and backend images. The backend
// part prefers the release version (SYRUS_VERSION baked into published
// images) and falls back to the revision (GIT_SHA) on dev builds; the
// desktop app announces its own build via a User-Agent token that carries
// the release version on release builds and the git sha otherwise.
// Hovering a segment shows its build time (from SYRUS_BUILT_AT / the
// SyrusDesktopBuiltAt UA token) — the quickest read on which part of a
// diverged pair is older. The container stays pointer-events-none so the
// badge never eats a click; only the text glyphs themselves re-enable
// pointer events, purely to receive hover for the native title tooltip.
export function BuildBadge({
  revision,
  version,
  builtAt
}: {
  revision?: string | null
  version?: string | null
  builtAt?: string | null
}) {
  const appBuild = desktopBuildSha()
  const backend = version || (revision && revision !== "dev" ? revision : null)
  if (!appBuild && !backend) return null

  const parts: Array<{ label: string; title: string | undefined }> = []
  if (appBuild) {
    const label = `app ${appBuild}`
    parts.push({ label, title: builtTooltip(label, desktopBuiltAt()) })
  }
  if (backend) {
    const label = `backend ${backend}`
    parts.push({ label, title: builtTooltip(label, builtAt) })
  }

  return (
    <div
      aria-hidden="true"
      className="pointer-events-none fixed bottom-1.5 right-2 z-40 select-none font-mono text-[10px] text-gray-400/80 dark:text-gray-600"
      data-testid="build-badge"
    >
      {parts.map((part, index) => (
        <Fragment key={part.label}>
          {index > 0 ? " · " : null}
          <span className="pointer-events-auto" title={part.title}>
            {part.label}
          </span>
        </Fragment>
      ))}
    </div>
  )
}
