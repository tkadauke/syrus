// Icon convention: fill="none" stroke="currentColor" strokeWidth="2" (outline glyphs); see StopIcon.tsx for the rare filled exception.
export function ChevronIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="m9 18 6-6-6-6" />
    </svg>
  )
}
