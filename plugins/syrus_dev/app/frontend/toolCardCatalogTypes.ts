import type { ToolPresentationEntry } from "@app/toolPresentationRegistry"

// Shared between AdminToolCards.tsx (the catalog page) and
// ToolCardDiscussDialog.tsx (the per-card "Discuss this card" feedback
// flow) so neither has to import from the other -- a page importing a
// component that imports back from the page is a needless circular
// dependency when the handful of shared bits fit in their own module.

export type RendererType = "custom_card" | "generic_fallback"

export function rendererTypeFor(entry: ToolPresentationEntry): RendererType {
  return entry.renderer ? "custom_card" : "generic_fallback"
}
