export const NOTICE_AUTO_DISMISS_DELAY_MS = 3_000
export const NOTICE_TRANSITION_MS = 250
export const NOTICE_TOAST_VIEWPORT_CLASS = "fixed right-4 top-[68px] z-50 max-w-sm sm:right-6 lg:top-4"
export const NOTICE_POPOVER_CLASS = "absolute left-0 top-full z-30 mt-2 w-80"
export const NOTICE_SIDEBAR_STACK_CLASS = "shrink-0 space-y-2 px-3 pb-2 empty:hidden"

export function noticeAnimationClass() {
  return "motion-safe:animate-notice-in"
}

export function noticeSurfaceClass(extra = "") {
  return [
    "rounded border border-border bg-surface px-4 py-3 text-sm text-text shadow-lg",
    noticeAnimationClass(),
    extra
  ].filter(Boolean).join(" ")
}

export function compactNoticeSurfaceClass(extra = "") {
  return [
    "rounded border border-border bg-surface px-2.5 py-2 text-xs text-text shadow-sm",
    noticeAnimationClass(),
    extra
  ].filter(Boolean).join(" ")
}

export function noticePopoverSurfaceClass(extra = "") {
  return [
    NOTICE_POPOVER_CLASS,
    "rounded border border-border bg-surface shadow-lg",
    noticeAnimationClass(),
    extra
  ].filter(Boolean).join(" ")
}
