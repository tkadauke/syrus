import { useT } from "../hooks/useT"
import { isDesktopTestChannel } from "../lib/desktopShell"

// An amber corner dot identifying an isolated side-by-side test build without
// adding to the brand lockup's flow or width. Renders nothing off the test
// channel. Callers place it inside a positioned parent; className overrides
// the corner offset.
export function TestChannelDot({ className }: { className?: string }) {
  const { t } = useT("common")
  if (!isDesktopTestChannel()) {
    return null
  }

  return (
    <span
      aria-label={t("test_channel_dot.tooltip")}
      data-testid="test-channel-dot"
      title={t("test_channel_dot.tooltip")}
      className={className ?? "absolute -right-0.5 -top-0.5 h-2.5 w-2.5 rounded-full bg-warning ring-2 ring-surface"}
    />
  )
}
