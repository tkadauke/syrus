import type { ReactNode } from "react"

// The shared visual language for every onboarding screen, so alignment and
// spacing can't drift per-screen again: centered title + centered one-line
// subtitle, left-aligned body, one footer convention (secondary action on
// the left edge, primary on the right, mt-6). Validation hints copy the web
// app's PasswordFeedback pattern — guidance-only, fade in, never block
// submission.

export function OnboardingScreen({
  title,
  titleTone = "default",
  subtitle,
  width = "md",
  children
}: {
  title: string
  titleTone?: "default" | "danger"
  subtitle?: ReactNode
  // Welcome's two-card grid needs xl; everything else is md so the width
  // doesn't jump while stepping through the flow.
  width?: "md" | "xl"
  children: ReactNode
}) {
  return (
    <section className={width === "xl" ? "w-full max-w-xl" : "w-full max-w-md"}>
      <h1 className={`text-center text-xl font-semibold ${titleTone === "danger" ? "text-red-700" : ""}`}>{title}</h1>
      {subtitle ? <p className="mt-2 text-center text-sm text-slate-600">{subtitle}</p> : null}
      {children}
    </section>
  )
}

export function FooterRow({ children }: { children: ReactNode }) {
  return <div className="mt-6 flex items-center justify-between gap-2">{children}</div>
}

// Async/server errors. role="alert" so screen readers announce them when
// they appear after a round-trip; visual language matches .form-error.
export function FormError({ children }: { children: ReactNode }) {
  if (!children) {
    return null
  }

  return (
    <p role="alert" className="border-l-[3px] border-red-600 pl-2.5 text-sm leading-5 text-red-800">
      {children}
    </p>
  )
}

export type HintState = "empty" | "valid" | "invalid" | "note"

// Line-height-stable live hint under an input: emerald check when the value
// looks right, amber guidance while it doesn't yet, slate for neutral notes.
export function ValidationHint({ state, children }: { state: HintState; children?: ReactNode }) {
  const tone =
    state === "valid"
      ? "text-emerald-600 opacity-100"
      : state === "invalid"
        ? "text-amber-600 opacity-100"
        : state === "note"
          ? "text-slate-500 opacity-100"
          : "opacity-0"

  return (
    <p aria-live="polite" className={`mt-1 flex min-h-4 items-center gap-1.5 text-xs font-normal transition-opacity duration-300 ${tone}`} data-testid="validation-hint">
      {state === "valid" ? (
        <svg aria-hidden="true" className="h-3.5 w-3.5 shrink-0" fill="none" stroke="currentColor" strokeWidth="2.5" viewBox="0 0 24 24">
          <path d="M5 13l4 4L19 7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
      <span className="min-w-0">{children ?? " "}</span>
    </p>
  )
}

export function Spinner({ className = "h-3 w-3" }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={`inline-block animate-spin rounded-full border-2 border-terracotta-500 border-t-transparent ${className}`}
    />
  )
}

// Slim determinate progress bar — same visual language as the Docker Desktop
// download bar on RuntimeSetup (slate track, terracotta fill).
export function ProgressBar({ percent }: { percent: number }) {
  const bounded = Math.max(0, Math.min(100, percent))

  return (
    <div
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={bounded}
      className="h-2 w-full overflow-hidden rounded-full bg-slate-200"
    >
      <div className="h-full rounded-full bg-terracotta-600 transition-all" style={{ width: `${bounded}%` }} />
    </div>
  )
}

export function LogTail({ lines, label = "Show details" }: { lines: string[]; label?: string }) {
  if (lines.length === 0) {
    return null
  }

  return (
    <details className="mt-4">
      <summary className="cursor-pointer text-xs text-slate-500">{label}</summary>
      <pre className="mt-2 max-h-40 overflow-y-auto whitespace-pre-wrap break-words rounded-lg bg-slate-900 p-3 text-xs leading-relaxed text-slate-200">
        {lines.join("\n")}
      </pre>
    </details>
  )
}
