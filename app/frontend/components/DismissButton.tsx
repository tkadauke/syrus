import { CloseIcon } from "./CloseIcon"

// Shared ghost "X" control for ephemeral notices — used by both the
// auto-dismiss toast and the shell sidebar's skill-offer notice, which
// otherwise hand-rolled the same inline-flex/rounded/hover-state button
// twice at two different sizes. `size` picks the preset that matches each
// call site's existing visuals (toast: larger, elevated; sidebar: compact,
// already-muted background) — no visual change, just one definition.
export function DismissButton({ label, onClick, size = "md" }: { label: string; onClick: () => void; size?: "sm" | "md" }) {
  const dimensions = size === "sm"
    ? "h-5 w-5 hover:bg-gray-200 hover:text-gray-600 dark:hover:bg-gray-700"
    : "-mr-1 h-6 w-6 hover:bg-gray-100 hover:text-gray-700 dark:hover:bg-gray-800"

  return (
    <button
      aria-label={label}
      className={`inline-flex items-center justify-center rounded text-gray-400 dark:text-gray-500 dark:hover:text-gray-300 ${dimensions}`}
      onClick={onClick}
      type="button"
    >
      <CloseIcon className={size === "sm" ? "h-3.5 w-3.5" : "h-4 w-4"} />
    </button>
  )
}
