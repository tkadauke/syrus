// Exception to the stroke convention (see ChevronIcon.tsx): a stop control
// reads as a solid square, so this one stays filled rather than outlined.
export function StopIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} viewBox="0 0 24 24">
      <rect fill="currentColor" height="14" rx="2" width="14" x="5" y="5" />
    </svg>
  )
}
