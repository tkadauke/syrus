import { BRAND_ICON_SRC } from "../lib/brandIcon"
import { isDesktopTestChannel } from "../lib/desktopShell"

export function SyrusBrand({ markOnly = false }: { markOnly?: boolean }) {
  // A side-by-side test build renders "Syrus Test" so the window is
  // unmistakable next to a production install (detected via the desktop
  // shell's SyrusDesktopChannel/test UA token; plain browsers show "Syrus").
  const name = isDesktopTestChannel() ? "Syrus Test" : "Syrus"
  return (
    <span className="inline-flex items-center gap-2">
      <img alt="" aria-hidden="true" className="h-6 w-6 shrink-0 rounded" src={BRAND_ICON_SRC} />
      {markOnly ? <span className="sr-only">{name}</span> : <span>{name}</span>}
    </span>
  )
}
