// Canonical Tailwind class for text/select form inputs, shared across the SPA.
// Uses the terracotta brand accent for the focus outline (blue-* renders the
// same via the palette remap in config/tailwind.config.js, but new code should
// name terracotta). Consolidated from several visually-identical copies.
//
// fullWidth defaults to true. Pass fullWidth: false for inline/compact controls
// (e.g. a per-row role <select>) instead of appending "w-auto" at the call
// site: Tailwind's generated stylesheet orders `w-full` after `w-auto`, so an
// appended "w-auto" loses the specificity tie and the element silently stays
// full width.
export function inputClass({ fullWidth = true }: { fullWidth?: boolean } = {}) {
  return `block ${fullWidth ? "w-full" : "w-auto"} rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-terracotta-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500`
}
