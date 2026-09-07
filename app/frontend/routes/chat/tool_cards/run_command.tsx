import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, Disclosure, displayValue, Row, truncateLines } from "../toolCardUi"

// Local Mode tool card for run_command (EPIC-293 / JOB-4225). A non-zero
// exit code or `killed` is a normal successful tool call (the command ran,
// it just failed/timed out), not a tool error, so this card is what
// surfaces command-failure output to the reviewer.
const OUTPUT_LINE_LIMIT = 200

type RunCommandResult = { stdout: string; stderr: string; exitCode: number; killed: boolean }

function parseResult(context: ToolCardContext): RunCommandResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  if (typeof parsed.stdout !== "string" || typeof parsed.stderr !== "string" || typeof parsed.exit_code !== "number") return null

  return { stdout: parsed.stdout, stderr: parsed.stderr, exitCode: parsed.exit_code, killed: parsed.killed === true }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.killed) return "Command killed (timeout)"
  return result.exitCode === 0 ? "Command succeeded (exit 0)" : `Command failed (exit ${result.exitCode})`
}

function ExitCodeBadge({ result }: { result: RunCommandResult }) {
  if (result.killed) {
    return <span className="rounded-full bg-amber-100 px-2 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">killed</span>
  }

  const tone = result.exitCode === 0
    ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200"
    : "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-200"
  return <span className={`rounded-full px-2 py-0.5 text-2xs font-semibold ${tone}`}>exit {result.exitCode}</span>
}

function OutputSection({ label, output }: { label: string; output: string }) {
  if (!output) return null
  const { preview, truncated, totalLines } = truncateLines(output, OUTPUT_LINE_LIMIT)

  return (
    <Disclosure label={label}>
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
      {truncated ? <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">Showing first {OUTPUT_LINE_LIMIT} of {totalLines} lines.</div> : null}
    </Disclosure>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  const command = displayValue(context.input?.command)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <ExitCodeBadge result={result} />
      </div>
      {command ? (
        <dl className="grid gap-1">
          <Row label="Command" value={command} />
        </dl>
      ) : null}
      <OutputSection label="stdout" output={result.stdout} />
      <OutputSection label="stderr" output={result.stderr} />
      {!result.stdout && !result.stderr ? <div className="text-gray-500 dark:text-gray-400">No output.</div> : null}
    </CardShell>
  )
}

const runCommandToolCard: ToolCardRenderer = {
  toolName: "run_command",
  collapsedSummary,
  renderExpanded
}

export default runCommandToolCard
