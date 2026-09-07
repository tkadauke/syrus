import { useTranslation } from "react-i18next"
import { useActiveShortcuts, type ShortcutRegistration } from "../contexts/ShortcutsContext"
import { CloseIcon } from "./CloseIcon"
import { Modal } from "./Modal"

function isMacPlatform(): boolean {
  if (typeof navigator === "undefined") return false
  return /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || "")
}

const MODIFIER_LABELS: Record<string, { mac: string; other: string }> = {
  mod: { mac: "⌘", other: "Ctrl" },
  alt: { mac: "⌥", other: "Alt" },
  shift: { mac: "⇧", other: "Shift" }
}

function formatKeyLabel(key: string): string {
  if (key.length === 1) return key.toUpperCase()
  return key.charAt(0).toUpperCase() + key.slice(1)
}

// Renders a combo string like "mod+shift+k" as platform-appropriate symbols
// (⌘⇧K on Mac, Ctrl+Shift+K elsewhere).
export function formatShortcutCombo(combo: string): string {
  const mac = isMacPlatform()
  const parts = combo.split("+").map((part) => part.trim()).filter(Boolean)
  const key = parts[parts.length - 1] ?? ""
  const modifiers = parts.slice(0, -1)
  const labels = modifiers.map((modifier) => MODIFIER_LABELS[modifier]?.[mac ? "mac" : "other"] ?? modifier)
  const formatted = [...labels, formatKeyLabel(key)]
  return mac ? formatted.join("") : formatted.join("+")
}

function groupShortcuts(shortcuts: ShortcutRegistration[]): Array<{ group: string; groupOrder: number; shortcuts: ShortcutRegistration[] }> {
  const byGroup = new Map<string, { group: string; groupOrder: number; shortcuts: ShortcutRegistration[] }>()

  shortcuts.forEach((shortcut) => {
    const existing = byGroup.get(shortcut.group)
    if (existing) {
      existing.shortcuts.push(shortcut)
    } else {
      byGroup.set(shortcut.group, { group: shortcut.group, groupOrder: shortcut.groupOrder ?? 0, shortcuts: [shortcut] })
    }
  })

  return Array.from(byGroup.values())
    .map((entry) => ({ ...entry, shortcuts: [...entry.shortcuts].sort((a, b) => a.description.localeCompare(b.description)) }))
    .sort((a, b) => a.groupOrder - b.groupOrder || a.group.localeCompare(b.group))
}

export function ShortcutsHelpModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { t } = useTranslation(["nav", "common"])
  const shortcuts = useActiveShortcuts()
  const groups = groupShortcuts(shortcuts)

  return (
    <Modal label={t("nav:shortcuts.title")} onClose={onClose} open={open}>
      <header className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("nav:shortcuts.title")}</h2>
        <button
          aria-label={t("common:close")}
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
                {entry.shortcuts.map((shortcut) => (
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
