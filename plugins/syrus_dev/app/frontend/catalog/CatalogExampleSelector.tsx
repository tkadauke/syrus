import { catalogTabClasses } from "./catalogTabClasses"

// Shared example-selector tab strip for syrus_dev's admin catalogs (Tool
// Card Catalog, Artifact Renderer Catalog). Renders nothing when there is
// only one (or zero) example -- a selector serves no purpose when there is
// nothing to switch between.

export type CatalogExampleOption = { id: string; label: string }

export function CatalogExampleSelector({
  ariaLabel,
  examples,
  onSelect,
  selectedId
}: {
  ariaLabel: string
  examples: CatalogExampleOption[]
  onSelect: (id: string) => void
  selectedId: string | null
}) {
  if (examples.length <= 1) return null

  return (
    <div aria-label={ariaLabel} className="flex flex-wrap gap-1.5" role="tablist">
      {examples.map((example) => (
        <button
          aria-selected={example.id === selectedId}
          className={catalogTabClasses(example.id === selectedId)}
          key={example.id}
          onClick={() => onSelect(example.id)}
          role="tab"
          type="button"
        >
          {example.label}
        </button>
      ))}
    </div>
  )
}
