export function PinIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" viewBox="0 0 24 24">
      <path
        d="M14.5 4.5 19.5 9.5M5 19l5.1-5.1M9 4.5h6l.7 4.3 2.8 2.8-2.9 2.9-2.8-2.8-4.3-.7v-6.5Z"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="1.8"
      />
    </svg>
  )
}
