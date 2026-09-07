import type { ReactNode } from "react"
import { isPlainObject } from "@app/pluginToolCards"
import { displayValue, InternalLink, numberValue, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation helpers for the test_insights plugin's chat tool cards
// (EPIC-292). list_repository_test_insights, read_test_insight, and
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

const REASON_CLASSES: Record<string, string> = {
  failing: "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300",
  flaky: "border-yellow-200 bg-yellow-50 text-yellow-800 dark:border-yellow-900 dark:bg-yellow-950 dark:text-yellow-300",
  slow: "border-info/30 bg-info/10 text-info"
}

export function ReasonBadges({ reasons }: { reasons: string[] }) {
  if (reasons.length === 0) return null

  return (
    <div className="flex flex-wrap gap-1">
      {reasons.map((reason) => (
        <span className={`inline-flex rounded border px-1.5 py-0.5 text-2xs font-medium ${REASON_CLASSES[reason] ?? "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300"}`} key={reason}>
          {reason}
        </span>
      ))}
    </div>
  )
}

export function TestStatusPill({ status }: { status: string | null }) {
  if (!status) return <span className="text-gray-400 dark:text-gray-500">—</span>

  const tone = status === "passed" ? "success" : status === "skipped" ? "neutral" : "failure"
  return <StatePill state={status} tone={tone} />
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
      {message ? <div className="whitespace-pre-wrap break-words text-red-700 dark:text-red-300">{message}</div> : null}
      {backtrace || output ? (
        <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
          <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
            Backtrace / output
          </summary>
          {backtrace ? <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words text-2xs text-gray-600 dark:text-gray-300">{backtrace}</pre> : null}
          {output ? <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words text-2xs text-gray-600 dark:text-gray-300">{output}</pre> : null}
        </details>
      ) : null}
    </div>
  )
}

export function Flakiness({ flakiness }: { flakiness: unknown }) {
  if (!isPlainObject(flakiness) || flakiness.flaky !== true) return null

  const score = numberValue(flakiness.score)
  return (
    <span className="inline-flex rounded-full bg-yellow-100 px-2 py-0.5 text-2xs font-semibold text-yellow-800 dark:bg-yellow-950/40 dark:text-yellow-200">
      flaky{score != null ? ` (${Math.round(score * 100)}%)` : ""}
    </span>
  )
}

export function TableShell({ children }: { children: ReactNode }) {
  return <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">{children}</div>
}
