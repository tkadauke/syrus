import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CopyIcon } from "../../../components/CopyableSlug"
import { useCopyToClipboard } from "../../../hooks/useCopyToClipboard"
import { redactToolCardText } from "../../../toolCardSecurity"
import { CardShell, Disclosure, displayValue, Row } from "../toolCardUi"
import { TextPreview } from "../toolCardMarkdown"

// Local Mode tool card for run_command (the tool-card work). A non-zero
// exit code or `killed` is a normal successful tool call (the command ran,
// it just failed/timed out), not a tool error, so this card is what
// surfaces command-failure output to the reviewer.
const OUTPUT_LINE_LIMIT = 200

type RunCommandResult = { kind: "command"; stdout: string; stderr: string; exitCode: number; killed: boolean } | { kind: "error"; error: string }

function parseResult(context: ToolCardContext): RunCommandResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  if (typeof parsed.error === "string" && parsed.error.trim()) return { kind: "error", error: parsed.error }
  if (typeof parsed.stdout !== "string" || typeof parsed.stderr !== "string" || typeof parsed.exit_code !== "number") return null

  return { kind: "command", stdout: parsed.stdout, stderr: parsed.stderr, exitCode: parsed.exit_code, killed: parsed.killed === true }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.kind === "error") return `Command error: ${redactToolCardText(result.error)}`
  if (result.killed) return "Command killed"
  return result.exitCode === 0 ? "Command succeeded (exit 0)" : `Command failed (exit ${result.exitCode})`
}

function ExitCodeBadge({ result }: { result: RunCommandResult }) {
  if (result.kind === "error") {
    return <span className="rounded-full bg-red-100 px-2 py-0.5 text-2xs font-semibold text-red-700 dark:bg-red-950/40 dark:text-red-200">error</span>
  }
  if (result.killed) {
    return <span className="rounded-full bg-amber-100 px-2 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">killed</span>
  }

  const tone = result.exitCode === 0
    ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200"
    : "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-200"
  return <span className={`rounded-full px-2 py-0.5 text-2xs font-semibold ${tone}`}>exit {result.exitCode}</span>
}

function OutputSection({ defaultOpen = false, label, output }: { defaultOpen?: boolean; label: string; output: string }) {
  if (!output) return null
  return (
    <Disclosure defaultOpen={defaultOpen} label={label}>
      <TextPreview maxLines={OUTPUT_LINE_LIMIT} text={redactToolCardText(output)} truncate="tail" />
    </Disclosure>
  )
}

function CommandBlock({ command }: { command: string }) {
  const { copied, copy } = useCopyToClipboard()
  const safeCommand = redactToolCardText(command)

  return (
    <div className="min-w-0">
      <div className="text-2xs font-semibold uppercase text-text-muted">Command</div>
      <div className="flex min-w-0 items-start gap-1">
        <pre className="min-w-0 flex-1 whitespace-pre-wrap break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]">{safeCommand}</pre>
        <button
          aria-label="Copy command"
          className="shrink-0 rounded p-1 text-text-subtle hover:bg-surface-raised hover:text-text-primary"
          onClick={() => copy(safeCommand)}
          title={copied ? "Copied" : "Copy command"}
          type="button"
        >
          <CopyIcon className="h-3.5 w-3.5" />
        </button>
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  const command = displayValue(context.input?.command)
  const cwd = displayValue(context.input?.cwd)
  const timeout = displayValue(context.input?.timeout_ms)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <ExitCodeBadge result={result} />
      </div>
      {command ? <CommandBlock command={command} /> : null}
      {cwd || timeout ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {cwd ? <Row label="Working directory" value={redactToolCardText(cwd)} /> : null}
          {timeout ? <Row label="Timeout (ms)" value={timeout} /> : null}
        </dl>
      ) : null}
      {result.kind === "error" ? (
        <div className="rounded-[var(--radius-panel)] border border-danger-border bg-danger-surface p-2 font-mono text-xs text-danger-text">
          {redactToolCardText(result.error)}
        </div>
      ) : (
        <>
          <OutputSection label="stdout" output={result.stdout} />
          <OutputSection defaultOpen={result.exitCode !== 0 && Boolean(result.stderr)} label="stderr" output={result.stderr} />
          {!result.stdout && !result.stderr ? <div className="text-text-muted">No output.</div> : null}
        </>
      )}
    </CardShell>
  )
}

const runCommandToolCard: ToolCardRenderer = {
  toolName: "run_command",
  collapsedSummary,
  renderExpanded
}

export default runCommandToolCard
