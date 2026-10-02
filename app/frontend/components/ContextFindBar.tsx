import { useEffect, useRef } from "react"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { Input } from "./Input"

export function ContextFindBar({
  closeLabel = "Close find",
  countLabel,
  hasResults,
  nextLabel = "Next match",
  onClose,
  onNext,
  onPrevious,
  onQueryChange,
  placeholder = "Find...",
  previousLabel = "Previous match",
  query,
}: {
  closeLabel?: string
  countLabel: string
  hasResults: boolean
  nextLabel?: string
  onClose: () => void
  onNext: () => void
  onPrevious: () => void
  onQueryChange: (query: string) => void
  placeholder?: string
  previousLabel?: string
  query: string
}) {
  const inputRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  return (
    <div className="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-3 py-2 text-xs" role="search">
      <Input
        aria-label="Find"
        className="min-w-0 flex-1"
        onChange={(event) => onQueryChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Escape") onClose()
          if (event.key === "Enter") {
            event.preventDefault()
            if (event.shiftKey) onPrevious()
            else onNext()
          }
        }}
        placeholder={placeholder}
        ref={inputRef}
        type="search"
        value={query}
      />
      <span className="shrink-0 text-text-secondary">{countLabel}</span>
      <Button aria-label={previousLabel} disabled={!hasResults} onClick={onPrevious} size="sm" title={previousLabel} variant="secondary">Prev</Button>
      <Button aria-label={nextLabel} disabled={!hasResults} onClick={onNext} size="sm" title={nextLabel} variant="secondary">Next</Button>
      <Button aria-label={closeLabel} className="h-7 w-7" onClick={onClose} size="icon" title={closeLabel} variant="secondary">
        <CloseIcon className="h-4 w-4" />
      </Button>
    </div>
  )
}
