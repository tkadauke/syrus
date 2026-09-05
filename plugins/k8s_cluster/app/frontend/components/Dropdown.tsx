import { useEffect, useRef, useState } from "react"
import { Button } from "@app/components/Button"

// Toolbar dropdown control (button+listbox), per CLAUDE.md's convention for
// small fixed-choice toolbar controls (chat mode/model/effort selectors) -
// never a native <select> for this kind of in-toolbar switcher.
export type DropdownOption<T extends string> = { value: T; label: string }

export function Dropdown<T extends string>({
  ariaLabel,
  onChange,
  options,
  placeholder,
  value
}: {
  ariaLabel: string
  onChange: (value: T) => void
  options: DropdownOption<T>[]
  placeholder?: string
  value: T
}) {
  const [open, setOpen] = useState(false)
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!open) return

    function handlePointerDown(event: PointerEvent) {
      const target = event.target as Node | null
      if (!target) return
      if (listRef.current?.contains(target)) return
      if (buttonRef.current?.contains(target)) return
      setOpen(false)
    }

    document.addEventListener("pointerdown", handlePointerDown)
    return () => document.removeEventListener("pointerdown", handlePointerDown)
  }, [open])

  const currentLabel = options.find((option) => option.value === value)?.label ?? placeholder ?? value

  return (
    <div className="relative inline-block">
      <Button
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-label={ariaLabel}
        className="!justify-start gap-1.5"
        onClick={() => setOpen((isOpen) => !isOpen)}
        ref={buttonRef}
        size="sm"
        variant="secondary"
      >
        <span className="max-w-[12rem] truncate">{currentLabel}</span>
        <svg aria-hidden="true" className="h-3 w-3 shrink-0" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
          <path d="M6 9l6 6 6-6" />
        </svg>
      </Button>
      {open ? (
        <div
          className="absolute left-0 top-full z-20 mt-1 max-h-72 min-w-[10rem] overflow-y-auto rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
          ref={listRef}
          role="listbox"
        >
          {options.map((option) => (
            <button
              aria-selected={option.value === value}
              className={`flex w-full items-center px-3 py-2 text-left text-sm ${
                option.value === value
                  ? "bg-brand/10 font-medium text-brand dark:text-brand-emphasis"
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
          ))}
        </div>
      ) : null}
    </div>
  )
}
