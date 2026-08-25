import { useEffect, useRef, useState } from "react"

export type MysqlPickerOption = { value: string; label: string }

// The custom button[aria-haspopup=listbox] + div[role=listbox] dropdown
// pattern from ChatModeSelector/ChatModelSelector (app/frontend/routes/chat/Compose.tsx),
// generalized into a reusable single-select picker for the query builder's
// table/column/aggregation/join/sort steps.
export function MysqlPickerDropdown({
  ariaLabel,
  disabled,
  options,
  placeholder,
  value,
  onChange
}: {
  ariaLabel: string
  disabled?: boolean
  options: MysqlPickerOption[]
  placeholder: string
  value: string | null
  onChange: (value: string) => void
}) {
  const [open, setOpen] = useState(false)
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const dropdownRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!open) return

    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null
      if (!target) return
      if (dropdownRef.current?.contains(target)) return
      if (buttonRef.current?.contains(target)) return
      setOpen(false)
    }

    document.addEventListener("pointerdown", handlePointerDown)
    return () => document.removeEventListener("pointerdown", handlePointerDown)
  }, [open])

  const currentLabel = options.find((option) => option.value === value)?.label ?? placeholder

  return (
    <div className="relative inline-block">
      <button
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-label={ariaLabel}
        className="flex min-h-8 items-center gap-1 rounded border border-gray-300 bg-white px-2.5 py-1 text-xs text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
        disabled={disabled}
        onClick={() => setOpen((current) => !current)}
        ref={buttonRef}
        type="button"
      >
        <span className="max-w-[12rem] truncate">{currentLabel}</span>
        <svg aria-hidden="true" className="h-3 w-3 shrink-0" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>
      {open ? (
        <div
          className="absolute left-0 top-full z-20 mt-1 max-h-64 min-w-[12rem] overflow-y-auto rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
          ref={dropdownRef}
          role="listbox"
        >
          {options.length === 0 ? (
            <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">{placeholder}</p>
          ) : (
            options.map((option) => (
              <button
                aria-selected={option.value === value}
                className={`flex w-full items-center px-3 py-1.5 text-left text-xs ${
                  option.value === value
                    ? "bg-terracotta-50 font-medium text-terracotta-700 dark:bg-terracotta-950 dark:text-terracotta-200"
                    : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
                }`}
                key={option.value}
                onClick={() => {
                  onChange(option.value)
                  setOpen(false)
                }}
                role="option"
                type="button"
              >
                {option.label}
              </button>
            ))
          )}
        </div>
      ) : null}
    </div>
  )
}
