// Canonical Tailwind class for text/select form inputs, shared across the SPA.
// Uses semantic border/focus tokens so authenticated app surfaces follow the
// signed-in user's selected theme. Consolidated from several visually-identical
// copies.
//
// fullWidth defaults to true. Pass fullWidth: false for inline/compact controls
// (e.g. a per-row role <select>) instead of appending "w-auto" at the call
// site: Tailwind's generated stylesheet orders `w-full` after `w-auto`, so an
// appended "w-auto" loses the specificity tie and the element silently stays
// full width.
export function inputClass({ fullWidth = true }: { fullWidth?: boolean } = {}) {
  return `block ${fullWidth ? "w-full" : "w-auto"} rounded border border-border bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500`
}
