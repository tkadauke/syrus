import type { ReactNode } from "react"
import i18n from "i18next"
import { CodeSurface, Pill, Text } from "@app/components/ui"
import { isPlainObject } from "@app/pluginToolCards"
import { displayValue, InternalLink, numberValue, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation helpers for the test_insights plugin's chat tool cards
// (the pending-action tool-card work). list_repository_test_insights, read_test_insight, and
// compare_test_runtime all echo the same `{id, suite_name, name, file_path,
// links: {app_path}}` TestIdentity reference shape (see
// plugins/test_insights/app/services/test_insights/{query,detail,runtime_comparison}.rb),
// and read_job_test_results/read_run_test_results/read_test_insight all echo
// `{message, backtrace, output}` failure snippets and `{slug, path}` run/job
// refs, so this module parses and renders those common subsets once.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason design_docs and
// scheduled_tasks keep their shared modules beside this one).
export type TestIdentityRef = {
  id: string
  suiteName: string | null
  name: string
  filePath: string | null
  appPath: string | null
}

export function parseTestIdentityRef(value: unknown): TestIdentityRef | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const name = displayValue(value.name)
  if (!id || !name) return null

  const links = isPlainObject(value.links) ? value.links : null

  return {
    id,
    suiteName: displayValue(value.suite_name),
    name,
    filePath: displayValue(value.file_path),
    appPath: links ? displayValue(links.app_path) : null
  }
}

export function TestIdentityLink({ test }: { test: TestIdentityRef }) {
  if (test.appPath) return <InternalLink href={test.appPath}>{test.name}</InternalLink>
  return <span className="font-medium text-gray-800 dark:text-gray-100">{test.name}</span>
}

export function parseReasons(value: unknown, key: string): string[] {
  if (!isPlainObject(value) || !Array.isArray(value[key])) return []
  return value[key].filter((reason): reason is string => typeof reason === "string")
}

const REASON_TONES: Record<string, "danger" | "warning" | "info" | "neutral"> = {
  failing: "danger",
  flaky: "warning",
  slow: "info"
}

export function ReasonBadges({ reasons }: { reasons: string[] }) {
  if (reasons.length === 0) return null

  return (
    <div className="flex flex-wrap gap-1">
      {reasons.map((reason) => (
        <Pill className="text-2xs" key={reason} tone={REASON_TONES[reason] ?? "neutral"}>
          {t(`reason_${reason}`, { defaultValue: reason })}
        </Pill>
      ))}
    </div>
  )
}

export function TestStatusPill({ status }: { status: string | null }) {
  if (!status) return <span className="text-gray-400 dark:text-gray-500">—</span>

  const tone = status === "passed" ? "success" : status === "skipped" ? "neutral" : "failure"
  return <StatePill state={t(`status_${status}`, { defaultValue: status })} tone={tone} />
}

export function formatMs(value: number | null | undefined): string {
  if (value == null) return "—"
  if (value < 1000) return `${Math.round(value)}ms`
  return `${(value / 1000).toFixed(2)}s`
}

export function formatFailureRate(value: number | null | undefined): string {
  if (value == null) return "—"
  return `${Math.round(value * 100)}%`
}

export type RunJobRef = { slug: string; path: string | null; title: string | null }

export function parseRunJobRef(value: unknown): RunJobRef | null {
  if (!isPlainObject(value)) return null
  const slug = displayValue(value.slug)
  if (!slug) return null

  return { slug, path: displayValue(value.path), title: displayValue(value.title) }
}

export function RefLink({ target }: { target: RunJobRef | null }) {
  if (!target) return null
  if (!target.path) return <span className="font-mono text-gray-600 dark:text-gray-300">{target.slug}</span>
  return <InternalLink href={target.path}>{target.slug}</InternalLink>
}

export type FailureSnippetData = { message?: unknown; backtrace?: unknown; output?: unknown }

export function parseFailure(value: unknown): FailureSnippetData | null {
  if (!isPlainObject(value)) return null
  return { message: value.message, backtrace: value.backtrace, output: value.output }
}

// Failure text is already byte-truncated server side (see
// TestInsights::Detail::FAILURE_SNIPPET_BYTES); the backtrace/output stay
// behind a <details> disclosure so a long stack trace doesn't dominate the
// card, mirroring scheduled_tasks' PromptDisclosure pattern.
export function FailureSnippet({ failure }: { failure: FailureSnippetData }) {
  const message = typeof failure.message === "string" ? failure.message.trim() : ""
  const backtrace = typeof failure.backtrace === "string" ? failure.backtrace.trim() : ""
  const output = typeof failure.output === "string" ? failure.output.trim() : ""
  if (!message && !backtrace && !output) return null

  return (
    <div className="space-y-1">
      {message ? <Text as="div" className="whitespace-pre-wrap break-words" tone="danger">{message}</Text> : null}
      {backtrace || output ? (
        <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
          <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">
            {t("tool_backtrace_output")}
          </summary>
          {backtrace ? <CodeSurface className="mt-1" code={backtrace} copyLabel="Copy backtrace" maxHeightClassName="max-h-72" /> : null}
          {output ? <CodeSurface className="mt-1" code={output} copyLabel="Copy output" maxHeightClassName="max-h-72" /> : null}
        </details>
      ) : null}
    </div>
  )
}

export function Flakiness({ flakiness }: { flakiness: unknown }) {
  if (!isPlainObject(flakiness) || flakiness.flaky !== true) return null

  const score = numberValue(flakiness.score)
  return (
    <Pill className="text-2xs font-semibold" tone="warning">
      {t("tool_flaky")}{score != null ? ` (${Math.round(score * 100)}%)` : ""}
    </Pill>
  )
}

export function TableShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">{children}</div>
}

export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`test_insights:${key}`, options)
}
