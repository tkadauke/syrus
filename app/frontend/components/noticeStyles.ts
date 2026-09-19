export const NOTICE_AUTO_DISMISS_DELAY_MS = 3_000
export const NOTICE_TRANSITION_MS = 250

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
