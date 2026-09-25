import { isDesktopTestChannel } from "../lib/desktopShell"

// Theme-aware winged-stylus mark: the rounded-square backdrop and the glyph
// are painted from semantic color tokens (`--color-brand`/`--color-on-brand`)
// instead of a static PNG, so switching color themes (built-in or custom)
// recolors the mark the same way it recolors buttons and links. See
// app/assets/tailwind/application.css for where those tokens are defined and
// app/frontend/contexts/ThemeContext.tsx for how custom themes apply them as
// runtime CSS custom properties.
export function SyrusMark({ className = "h-6 w-6" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={`shrink-0 ${className}`} data-testid="syrus-mark" viewBox="0 0 24 24">
      <rect fill="var(--color-brand)" height="22" rx="6" width="22" x="1" y="1" />
      <g fill="var(--color-on-brand)" transform="rotate(-45 12 12)">
        <circle cx="12" cy="4.3" r="2.1" />
        <rect height="11" width="3" x="10.5" y="6" />
        <polygon points="10.5,17 13.5,17 12,20.5" />
        <path d="M10.5,9 C8.3,8.1 6.5,8.5 4.5,7.1 C6.1,8.9 5.5,10.1 3.5,10.8 C5.9,11.1 7.1,12.1 5.1,13.4 C7.7,12.7 9.3,11.1 10.5,9 Z" />
        <path d="M13.5,13 C15.7,13.9 17.5,13.5 19.5,14.9 C17.9,13.1 18.5,11.9 20.5,11.2 C18.1,10.9 16.9,9.9 18.9,8.6 C16.3,9.3 14.7,10.9 13.5,13 Z" />
      </g>
    </svg>
  )
}

export function SyrusBrand({ markOnly = false }: { markOnly?: boolean }) {
  // A side-by-side test build renders "Syrus Test" so the window is
  // unmistakable next to a production install (detected via the desktop
  // shell's SyrusDesktopChannel/test UA token; plain browsers show "Syrus").
  const name = isDesktopTestChannel() ? "Syrus Test" : "Syrus"
  return (
    <span className="inline-flex items-center gap-2">
      <SyrusMark />
      {markOnly ? <span className="sr-only">{name}</span> : <span>{name}</span>}
    </span>
  )
}
