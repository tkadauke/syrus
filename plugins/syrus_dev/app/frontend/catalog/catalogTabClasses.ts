// Shared "pill tab" styling for syrus_dev's admin catalogs (Tool Card
// Catalog, Artifact Renderer Catalog): the viewport switcher and the
// example selector both render a strip of small selectable tabs and need
// the exact same selected/unselected look.
export function catalogTabClasses(selected: boolean): string {
  return selected
    ? "rounded-[var(--radius-control)] border border-brand bg-brand px-2 py-1 text-xs font-medium text-on-brand"
    : "rounded-[var(--radius-control)] border border-border bg-surface px-2 py-1 text-xs font-medium text-text-secondary hover:bg-surface-raised"
}
