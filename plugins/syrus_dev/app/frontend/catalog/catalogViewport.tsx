import { forwardRef, type ReactNode } from "react"
import { Link } from "react-router-dom"
import { catalogTabClasses } from "./catalogTabClasses"

// Shared viewport review presets for syrus_dev's admin catalogs (Tool Card
// Catalog, Artifact Renderer Catalog). Widths are the same rough breakpoints
// Syrus's own visual_review agent step targets, not exact device
// dimensions -- extracted so both catalogs review responsive behavior the
// same way instead of maintaining two copies of this switcher.

export type ViewportPresetId = "phone" | "tablet" | "desktop" | "wide"

export type ViewportPreset = { id: ViewportPresetId; width: number }

export const CATALOG_VIEWPORT_PRESETS: ReadonlyArray<ViewportPreset> = [
  { id: "phone", width: 390 },
  { id: "tablet", width: 768 },
  { id: "desktop", width: 1280 },
  { id: "wide", width: 1600 }
]

export const DEFAULT_CATALOG_VIEWPORT: ViewportPresetId = "desktop"

export function viewportPresetFromSearch(search: string): ViewportPreset {
  const value = new URLSearchParams(search).get("viewport")
  return (
    CATALOG_VIEWPORT_PRESETS.find((preset) => preset.id === value) ??
    CATALOG_VIEWPORT_PRESETS.find((preset) => preset.id === DEFAULT_CATALOG_VIEWPORT)!
  )
}

export function viewportLink(pathname: string, search: string, presetId: ViewportPresetId) {
  const params = new URLSearchParams(search)
  params.set("viewport", presetId)
  return `${pathname}?${params.toString()}`
}

// Renders each preset as a link (not a button) so the selected viewport
// survives a page reload/share the same way every other catalog filter
// does -- clicking a preset just navigates to a URL with `?viewport=...` set.
export function CatalogViewportSwitcher({
  ariaLabel,
  labelFor,
  pathname,
  search,
  selected
}: {
  ariaLabel: string
  labelFor: (preset: ViewportPreset) => string
  pathname: string
  search: string
  selected: ViewportPresetId
}) {
  return (
    <div aria-label={ariaLabel} className="flex flex-wrap gap-1.5" role="tablist">
      {CATALOG_VIEWPORT_PRESETS.map((preset) => (
        <Link
          aria-selected={preset.id === selected}
          className={catalogTabClasses(preset.id === selected)}
          key={preset.id}
          role="tab"
          to={viewportLink(pathname, search, preset.id)}
        >
          {labelFor(preset)}
        </Link>
      ))}
    </div>
  )
}

export const CatalogViewportFrame = forwardRef<HTMLDivElement, {
  ariaLabel: string
  children: ReactNode
  className?: string
  width: number
}>(({ ariaLabel, children, className = "", width }, ref) => (
  <div className="overflow-x-auto">
    {/* Explicit `width`, not `max-width`: a block element with only
        `max-width` never grows past its parent's actual available width, so
        a preset wider than the ambient page content can silently collapse
        instead of applying the chosen width and scrolling. */}
    <div
      aria-label={ariaLabel}
      className={`mx-auto rounded-[var(--radius-control)] border border-dashed border-border bg-surface p-3 ${className}`}
      ref={ref}
      style={{ width: `${width}px` }}
    >
      {children}
    </div>
  </div>
))

CatalogViewportFrame.displayName = "CatalogViewportFrame"
