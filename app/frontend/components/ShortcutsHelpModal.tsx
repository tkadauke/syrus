import { useTranslation } from "react-i18next"
import { useActiveShortcuts, type ShortcutRegistration } from "../contexts/ShortcutsContext"
import { CloseIcon } from "./CloseIcon"
import { Modal } from "./Modal"

// Renders a combo string like "mod+enter" as title-cased tokens joined by
// " + " (Mod + Enter). A bare symbol combo like "?" -- only reachable via
// Shift on most layouts -- is left untouched rather than title-cased into
// something that no longer matches the key the user actually presses.
export function formatShortcutCombo(combo: string): string {
  const parts = combo.split("+").map((part) => part.trim()).filter(Boolean)
  if (parts.length === 1 && parts[0].length === 1 && !/[a-z0-9]/i.test(parts[0])) return parts[0]
  return parts.map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()).join(" + ")
}

export interface ShortcutGroupSummary<T> {
  group: string
  groupOrder: number
  items: T[]
}

// Groups a live shortcut snapshot by each registration's `group` label,
// ordered by the lowest groupOrder seen for that group (ties alphabetical by
// group name). Items keep the registry's own order within a group.
export function groupActiveShortcuts<T extends { group: string; groupOrder?: number }>(items: T[]): ShortcutGroupSummary<T>[] {
  const byGroup = new Map<string, ShortcutGroupSummary<T>>()

  items.forEach((item) => {
    const groupOrder = item.groupOrder ?? 0
    const existing = byGroup.get(item.group)
    if (existing) {
      existing.items.push(item)
      existing.groupOrder = Math.min(existing.groupOrder, groupOrder)
    } else {
      byGroup.set(item.group, { group: item.group, groupOrder, items: [item] })
    }
  })

  return Array.from(byGroup.values()).sort((a, b) => a.groupOrder - b.groupOrder || a.group.localeCompare(b.group))
}

// Renders a live snapshot of the shortcut registry -- it reads the same
// registry useShortcut writes to, so it can never list a shortcut that isn't
// actually mounted and unshadowed right now.
export function ShortcutsHelpModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { t } = useTranslation("nav")
  const shortcuts = useActiveShortcuts()
  const groups = groupActiveShortcuts<ShortcutRegistration>(shortcuts)

  return (
    <Modal label={t("nav:shortcuts.title")} onClose={onClose} open={open}>
      <header className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("nav:shortcuts.title")}</h2>
        <button
          aria-label={t("nav:shortcuts.close")}
          className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-white"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </header>
      <div className="mt-3 max-h-[60vh] space-y-4 overflow-y-auto">
        {groups.length === 0 ? (
          <p className="text-sm text-gray-500 dark:text-gray-400">{t("nav:shortcuts.empty")}</p>
        ) : (
          groups.map((entry) => (
            <div key={entry.group}>
              <h3 className="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{entry.group}</h3>
              <ul className="mt-1.5 divide-y divide-gray-100 dark:divide-gray-800">
                {entry.items.map((shortcut) => (
                  <li className="flex items-center justify-between gap-4 py-1.5 text-sm" key={`${shortcut.group}-${shortcut.keys}-${shortcut.id}`}>
                    <span className="text-gray-700 dark:text-gray-300">{shortcut.description}</span>
                    <kbd className="rounded border border-gray-300 bg-gray-50 px-1.5 py-0.5 font-mono text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">
                      {formatShortcutCombo(shortcut.keys)}
                    </kbd>
                  </li>
                ))}
              </ul>
            </div>
          ))
        )}
      </div>
    </Modal>
  )
}
