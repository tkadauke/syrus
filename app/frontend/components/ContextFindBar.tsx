import { useEffect, useRef } from "react"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { Input } from "./Input"
import { useT } from "../hooks/useT"

export function ContextFindBar({
  closeLabel,
  countLabel,
  hasResults,
  nextLabel,
  onClose,
  onNext,
  onPrevious,
  onQueryChange,
  placeholder,
  previousLabel,
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
  const { t } = useT("common")
  const inputRef = useRef<HTMLInputElement | null>(null)
  const resolvedCloseLabel = closeLabel ?? t("find_bar.close")
  const resolvedNextLabel = nextLabel ?? t("find_bar.next_match")
  const resolvedPreviousLabel = previousLabel ?? t("find_bar.previous_match")
  const resolvedPlaceholder = placeholder ?? t("find_bar.placeholder")

  useEffect(() => {
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [])

  return (
    <div className="flex shrink-0 items-center gap-2 border-b border-border bg-surface px-3 py-2 text-xs" role="search">
      <Input
        aria-label={t("find_bar.input_label")}
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
        placeholder={resolvedPlaceholder}
        ref={inputRef}
        type="search"
        value={query}
      />
      <span className="shrink-0 text-text-secondary">{countLabel}</span>
      <Button aria-label={resolvedPreviousLabel} disabled={!hasResults} onClick={onPrevious} size="sm" title={resolvedPreviousLabel} variant="secondary">{t("find_bar.previous_short")}</Button>
      <Button aria-label={resolvedNextLabel} disabled={!hasResults} onClick={onNext} size="sm" title={resolvedNextLabel} variant="secondary">{t("find_bar.next_short")}</Button>
      <Button aria-label={resolvedCloseLabel} className="h-7 w-7" onClick={onClose} size="icon" title={resolvedCloseLabel} variant="secondary">
        <CloseIcon className="h-4 w-4" />
      </Button>
    </div>
  )
}
