import { isPlainObject, type ToolCardContext, type ToolCardExample } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"

type ContentBlock = Record<string, unknown>

type WalkthroughSection = {
  title: string
  range: string | null
  summary: string | null
}

type WalkthroughIssue = {
  title: string
  severity: string | null
  surface: string | null
  timestamp: string | null
  status: string | null
  details: string[]
}

type MediaReference = {
  label: string
  timestamp: string | null
  mimeType: string | null
}

type FullAnalysisCard = {
  summary: string | null
  sections: WalkthroughSection[]
  issues: WalkthroughIssue[]
  issueCount: number
  transcript: string[]
  openQuestions: string[]
  media: MediaReference[]
  empty: boolean
  error: string | null
}

type SegmentCard = {
  walkthroughId: string | null
  range: string | null
  focus: string | null
  note: string | null
  analysis: Record<string, unknown> | string | null
  observations: string[]
  issues: WalkthroughIssue[]
  timestamps: string[]
  error: string | null
}

const SEVERITY_TONES: Record<string, "failure" | "warning" | "success" | "neutral"> = {
  critical: "failure",
  high: "failure",
  medium: "warning",
  low: "success"
}

function contentBlocks(value: unknown): ContentBlock[] {
  if (Array.isArray(value)) return value.filter(isPlainObject)
  if (isPlainObject(value) && Array.isArray(value.content)) return value.content.filter(isPlainObject)
  if (isPlainObject(value) && isPlainObject(value.result) && Array.isArray(value.result.content)) return value.result.content.filter(isPlainObject)
  return []
}

function objectPayload(value: unknown): Record<string, unknown> | null {
  if (!isPlainObject(value)) return null
  if (isPlainObject(value.structured_content)) return value.structured_content
  if (isPlainObject(value.result) && isPlainObject(value.result.structured_content)) return value.result.structured_content
  return value
}

function textBlocks(context: ToolCardContext): string[] {
  const blockTexts = contentBlocks(context.parsedResult)
    .filter((block) => block.type === "text")
    .map((block) => displayValue(block.text))
    .filter((value): value is string => Boolean(value))
  if (blockTexts.length > 0) return blockTexts
  return context.resultBody.trim() ? [context.resultBody.trim()] : []
}

function firstReportText(context: ToolCardContext): string | null {
  return textBlocks(context).find((text) => text.includes("## Session summary") || text.includes("## Issues found")) ?? null
}

function sectionText(report: string, heading: string): string | null {
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const match = report.match(new RegExp(`## ${escaped}(?: \\([^\\n]+\\))?\\n([\\s\\S]*?)(?=\\n## |$)`))
  return match?.[1]?.trim() || null
}

function parseFullAnalysis(context: ToolCardContext): FullAnalysisCard | null {
  const report = firstReportText(context)
  const error = context.resultError ? textBlocks(context).join("\n").trim() || "Walkthrough analysis failed." : null
  if (!report && !error) return null

  const issues = report ? parseIssues(report) : []
  return {
    summary: report ? sectionText(report, "Session summary") : null,
    sections: report ? parseSections(report) : [],
    issues,
    issueCount: countFromHeading(report) ?? issues.length,
    transcript: report ? lines(sectionText(report, "Narration transcript")) : [],
    openQuestions: report ? bulletTexts(sectionText(report, "Open questions from the analysis")) : [],
    media: mediaReferences(context),
    empty: Boolean(report?.includes("(none") || (issues.length === 0 && report?.includes("## Issues found"))),
    error
  }
}

function parseSections(report: string): WalkthroughSection[] {
  return bulletTexts(sectionText(report, "Sections")).map((line) => {
    const match = line.match(/^\*\*(.+?)\*\*(?: \((.+?)\))?(?: — (.+))?$/)
    return {
      title: match?.[1] || line,
      range: match?.[2] || null,
      summary: match?.[3] || null
    }
  })
}

function parseIssues(report: string): WalkthroughIssue[] {
  const body = sectionText(report, "Issues found")
  if (!body || body.includes("(none")) return []

  const entries = body
    .split(/\n(?=- \*\*)/)
    .map((entry) => entry.trim())
    .filter(Boolean)
  return entries.map((entry) => {
    const rows = entry
      .split("\n")
      .map((row) => row.trim())
      .filter(Boolean)
    const head = rows[0] || ""
    const match = head.match(/^- \*\*(.+?)\*\*(?: \((.+?)\))?/)
    const meta = (match?.[2] || "")
      .split(",")
      .map((part) => part.trim())
      .filter(Boolean)
    return {
      title: match?.[1] || head.replace(/^- /, ""),
      severity: meta[0] || null,
      surface: meta.find((part, index) => index > 0 && !part.startsWith("at ") && !part.includes("look") && !part.includes("flagged")) || null,
      timestamp: meta.find((part) => part.startsWith("at "))?.replace(/^at /, "") || null,
      status: meta.find((part) => part.includes("look") || part.includes("flagged")) || null,
      details: rows.slice(1)
    }
  })
}

function countFromHeading(report: string | null): number | null {
  const match = report?.match(/## Issues found \((\d+)\)/)
  return match ? Number(match[1]) : null
}

function lines(text: string | null): string[] {
  return (
    text
      ?.split("\n")
      .map((line) => line.trim())
      .filter(Boolean) ?? []
  )
}

function bulletTexts(text: string | null): string[] {
  return lines(text)
    .map((line) => line.replace(/^- /, "").trim())
    .filter(Boolean)
}

function mediaReferences(context: ToolCardContext): MediaReference[] {
  const blocks = contentBlocks(context.parsedResult)
  const media: MediaReference[] = []
  let pendingLabel: string | null = null
  let pendingTimestamp: string | null = null

  for (const block of blocks) {
    if (block.type === "text") {
      const text = displayValue(block.text)
      const match = text?.match(/^Screenshot — (.+?) \(at (.+?)\):$/)
      if (match) {
        pendingLabel = match[1]
        pendingTimestamp = match[2]
      }
    }
    if (block.type === "image") {
      media.push({
        label: pendingLabel || displayValue(block.title) || "Walkthrough frame",
        timestamp: pendingTimestamp,
        mimeType: displayValue(block.mimeType) || displayValue(block.mime_type) || null
      })
      pendingLabel = null
      pendingTimestamp = null
    }
  }

  return media
}

export function fullAnalysisSummary(context: ToolCardContext) {
  const card = parseFullAnalysis(context)
  if (!card) return null
  if (card.error) return "Walkthrough analysis failed"
  const segments = card.sections.length === 1 ? "1 segment" : `${card.sections.length} segments`
  const issues = card.issueCount === 1 ? "1 issue" : `${card.issueCount} issues`
  const media = card.media.length > 0 ? `, ${card.media.length} frame${card.media.length === 1 ? "" : "s"}` : ""
  return card.empty ? `Walkthrough analysis: no issues across ${segments}${media}` : `Walkthrough analysis: ${issues} across ${segments}${media}`
}

export function renderFullAnalysis(context: ToolCardContext) {
  const card = parseFullAnalysis(context)
  return card ? <FullAnalysisBody card={card} /> : null
}

function FullAnalysisBody({ card }: { card: FullAnalysisCard }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Walkthrough analysis</Badge>
        <StatePill
          state={card.error ? "failed" : card.empty ? "no issues" : "issues found"}
          tone={card.error ? "failure" : card.empty ? "success" : "warning"}
        />
        {!card.error ? (
          <Badge>
            {card.issueCount} issue{card.issueCount === 1 ? "" : "s"}
          </Badge>
        ) : null}
      </div>
      {card.error ? <RecoveryPanel message={card.error} /> : null}
      {card.summary ? <p className="text-sm text-text-primary">{card.summary}</p> : null}
      {!card.error ? (
        <dl className="grid gap-1 sm:grid-cols-3">
          <Row label="Segments" value={String(card.sections.length)} />
          <Row label="Issues" value={String(card.issueCount)} />
          <Row label="Frames" value={String(card.media.length)} />
        </dl>
      ) : null}
      {card.sections.length > 0 ? <SectionsList sections={card.sections} /> : null}
      {card.issues.length > 0 ? <IssuesList issues={card.issues} /> : card.empty ? <EmptyState>No issues were detected in this walkthrough.</EmptyState> : null}
      {card.media.length > 0 ? <MediaList media={card.media} /> : null}
      {card.openQuestions.length > 0 ? <CompactList label="Open questions" items={card.openQuestions} /> : null}
      {card.transcript.length > 0 ? (
        <Disclosure label="Narration transcript">
          <div className="max-h-64 space-y-1 overflow-auto text-xs">
            {card.transcript.map((line, index) => (
              <div className="break-words font-mono" key={`${line}-${index}`}>
                {line}
              </div>
            ))}
          </div>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

function SectionsList({ sections }: { sections: WalkthroughSection[] }) {
  return (
    <div className="space-y-1">
      <SectionLabel>Segments</SectionLabel>
      <div className="divide-y divide-border rounded-[var(--radius-panel)] border border-border">
        {sections.map((section) => (
          <div className="grid gap-1 px-2 py-1.5 sm:grid-cols-[8rem_minmax(0,1fr)]" key={`${section.title}-${section.range}`}>
            <div className="font-mono text-xs text-text-muted">{section.range || "time n/a"}</div>
            <div className="min-w-0">
              <div className="truncate text-sm font-medium text-text-primary" title={section.title}>
                {section.title}
              </div>
              {section.summary ? <div className="text-xs text-text-muted">{section.summary}</div> : null}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function IssuesList({ issues }: { issues: WalkthroughIssue[] }) {
  return (
    <div className="space-y-1">
      <SectionLabel>Key findings</SectionLabel>
      <div className="space-y-1">
        {issues.map((issue) => (
          <div className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1.5" key={`${issue.title}-${issue.timestamp}`}>
            <div className="flex flex-wrap items-center gap-2">
              <span className="min-w-0 flex-1 truncate text-sm font-medium text-text-primary" title={issue.title}>
                {issue.title}
              </span>
              {issue.severity ? <StatePill state={issue.severity} tone={SEVERITY_TONES[issue.severity.toLowerCase()] ?? "neutral"} /> : null}
              {issue.status ? <StatePill state={issue.status} tone="warning" /> : null}
            </div>
            <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-muted">
              {issue.timestamp ? <span className="font-mono">{issue.timestamp}</span> : null}
              {issue.surface ? <span>{issue.surface}</span> : null}
            </div>
            {issue.details.length > 0 ? (
              <ul className="mt-1 space-y-0.5 text-xs text-text-secondary">
                {issue.details.map((detail, index) => (
                  <li className="break-words" key={`${detail}-${index}`}>
                    {detail}
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        ))}
      </div>
    </div>
  )
}

function MediaList({ media }: { media: MediaReference[] }) {
  return (
    <div className="space-y-1">
      <SectionLabel>Frame references</SectionLabel>
      <div className="grid gap-1 sm:grid-cols-2">
        {media.map((item, index) => (
          <div className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1.5" key={`${item.label}-${index}`}>
            <div className="truncate text-sm font-medium text-text-primary" title={item.label}>
              {item.label}
            </div>
            <div className="mt-1 flex flex-wrap gap-2 text-xs text-text-muted">
              {item.timestamp ? <span className="font-mono">{item.timestamp}</span> : null}
              {item.mimeType ? <span>{item.mimeType}</span> : null}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function CompactList({ label, items }: { label: string; items: string[] }) {
  return (
    <div className="space-y-1">
      <SectionLabel>{label}</SectionLabel>
      <ul className="space-y-0.5 text-xs text-text-secondary">
        {items.map((item, index) => (
          <li className="break-words" key={`${item}-${index}`}>
            {item}
          </li>
        ))}
      </ul>
    </div>
  )
}

function parseSegment(context: ToolCardContext): SegmentCard | null {
  const payload = objectPayload(context.parsedResult)
  const error = context.resultError ? textBlocks(context).join("\n").trim() || "Segment analysis failed." : null
  if (!payload && !error) return null
  const analysis = payload ? payload.analysis : null

  return {
    walkthroughId: displayValue(payload?.walkthrough_id) || displayValue(context.input?.walkthrough_id),
    range: displayValue(payload?.range) || inputRange(context),
    focus: displayValue(payload?.focus) || displayValue(context.input?.focus),
    note: displayValue(payload?.note),
    analysis: normalizeAnalysis(analysis),
    observations: analysisObservations(analysis),
    issues: analysisIssues(analysis),
    timestamps: analysisTimestamps(analysis),
    error
  }
}

function inputRange(context: ToolCardContext): string | null {
  const start = displayValue(context.input?.start)
  const end = displayValue(context.input?.end)
  return start && end ? `${start}-${end}` : null
}

function normalizeAnalysis(analysis: unknown): Record<string, unknown> | string | null {
  if (isPlainObject(analysis)) return analysis
  return displayValue(analysis)
}

function analysisObservations(analysis: unknown): string[] {
  if (isPlainObject(analysis)) {
    const candidates = [analysis.observations, analysis.key_findings, analysis.findings, analysis.summary, analysis.details]
    return candidates.flatMap(stringList)
  }
  return stringList(analysis)
}

function analysisIssues(analysis: unknown): WalkthroughIssue[] {
  if (!isPlainObject(analysis) || !Array.isArray(analysis.issues)) return []
  return analysis.issues.filter(isPlainObject).map((issue) => ({
    title: displayValue(issue.title) || displayValue(issue.description) || "Segment issue",
    severity: displayValue(issue.severity),
    surface: displayValue(issue.surface),
    timestamp: displayValue(issue.timestamp),
    status: displayValue(issue.status),
    details: [displayValue(issue.description), displayValue(issue.evidence), displayValue(issue.recommendation)].filter((value): value is string =>
      Boolean(value)
    )
  }))
}

function analysisTimestamps(analysis: unknown): string[] {
  if (!isPlainObject(analysis)) return []
  return stringList(analysis.relevant_timestamps || analysis.timestamps)
}

function stringList(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(displayValue).filter((item): item is string => Boolean(item))
  const single = displayValue(value)
  return single ? [single] : []
}

export function segmentSummary(context: ToolCardContext) {
  const card = parseSegment(context)
  if (!card) return null
  if (card.error) return "Segment analysis failed"
  const subject = card.range ? `Segment ${card.range}` : "Segment analysis"
  const findings =
    card.issues.length > 0
      ? `${card.issues.length} issue${card.issues.length === 1 ? "" : "s"}`
      : `${card.observations.length || (card.analysis ? 1 : 0)} finding${card.observations.length === 1 ? "" : "s"}`
  return `${subject}: ${findings}`
}

export function renderSegment(context: ToolCardContext) {
  const card = parseSegment(context)
  return card ? <SegmentBody card={card} /> : null
}

function SegmentBody({ card }: { card: SegmentCard }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Walkthrough segment</Badge>
        <StatePill state={card.error ? "failed" : "analyzed"} tone={card.error ? "failure" : "success"} />
      </div>
      {card.error ? <RecoveryPanel message={card.error} /> : null}
      <dl className="grid gap-1 sm:grid-cols-3">
        {card.walkthroughId ? <Row label="Walkthrough ID" value={card.walkthroughId} /> : null}
        {card.range ? <Row label="Range" value={card.range} /> : null}
        {card.focus ? <Row label="Focus" value={card.focus} /> : null}
      </dl>
      {card.note ? (
        <div className="rounded-[var(--radius-panel)] border border-warning-border bg-warning-surface px-2 py-1 text-xs text-warning-text">{card.note}</div>
      ) : null}
      {card.issues.length > 0 ? <IssuesList issues={card.issues} /> : null}
      {card.observations.length > 0 ? <CompactList label="Observations" items={card.observations} /> : null}
      {card.timestamps.length > 0 ? <CompactList label="Relevant timestamps" items={card.timestamps} /> : null}
      {!card.error && card.analysis ? (
        <Disclosure label="Analysis payload">
          <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">
            {typeof card.analysis === "string" ? card.analysis : JSON.stringify(card.analysis, null, 2)}
          </pre>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

function RecoveryPanel({ message }: { message: string }) {
  return (
    <div className="space-y-1 rounded-[var(--radius-panel)] border border-danger-border bg-danger-surface px-2 py-1.5">
      <div className="text-sm font-medium text-danger-text">{message}</div>
      <ul className="space-y-0.5 text-xs text-danger-text">
        <li>Check that the walkthrough is analyzed and belongs to this chat.</li>
        <li>Retry a shorter time range if Gemini quota or segment length caused the failure.</li>
        <li>Record a fresh walkthrough if the stored video or retained upload expired.</li>
      </ul>
    </div>
  )
}

export const fullAnalysisExamples: ToolCardExample[] = [
  {
    id: "full_analysis",
    label: "Full analysis with issues",
    input: { walkthrough_id: 42 },
    parsedResult: {
      content: [
        {
          type: "text",
          text: [
            "## Session summary",
            "Checkout works until Save silently fails.",
            "",
            "## Sections",
            "- **Checkout path** (00:00–00:40) — The user completes payment.",
            "- **Settings save** (01:05–01:30) — The save button appears inert.",
            "",
            "## Issues found (2)",
            "- **Save button does nothing** (high, settings, at 01:12, needs a closer look)",
            "  No confirmation or validation appears after Save.",
            "  On screen: A red toast appears but the code is too small.",
            "- **Low contrast helper text** (low, settings, at 00:20)",
            "  Gray helper text blends into the panel.",
            "",
            "## Narration transcript",
            "[01:12] I click save and nothing happens.",
            "",
            "## Open questions from the analysis",
            "The analysis flagged these ambiguities:",
            "- Should drafts autosave?"
          ].join("\n")
        },
        { type: "text", text: "Screenshot — Save button does nothing (at 1:12):" },
        { type: "image", data: "jpeg", mimeType: "image/jpeg" }
      ]
    }
  },
  {
    id: "empty_analysis",
    label: "No issues analysis",
    input: { walkthrough_id: 43 },
    parsedResult: {
      content: [
        {
          type: "text",
          text: [
            "## Session summary",
            "The walkthrough completed without visible errors.",
            "",
            "## Sections",
            "- **Happy path** (00:00–00:55) — The task completes.",
            "",
            "## Issues found",
            "(none — the walkthrough surfaced no problems)"
          ].join("\n")
        }
      ]
    }
  }
]

export const segmentExamples: ToolCardExample[] = [
  {
    id: "segment_analysis",
    label: "Segment analysis with findings",
    input: { walkthrough_id: 42, start: "01:10", end: "01:30", focus: "the exact error text" },
    parsedResult: {
      walkthrough_id: 42,
      range: "1:10–1:30",
      focus: "the exact error text",
      analysis: {
        observations: ["The toast reads Save failed (E_TIMEOUT).", "The spinner remains active after the toast disappears."],
        relevant_timestamps: ["1:12", "1:18"],
        issues: [
          {
            title: "Save timeout is visible",
            severity: "high",
            timestamp: "1:12",
            description: "The exact toast text is visible in the zoomed segment.",
            evidence: "Save failed (E_TIMEOUT)"
          }
        ]
      }
    }
  },
  {
    id: "segment_failure",
    label: "Segment analysis failure",
    input: { walkthrough_id: 42, start: "01:10", end: "08:30", focus: "everything" },
    resultError: true,
    resultBody: JSON.stringify({
      content: [{ type: "text", text: "Gemini's quota is busy right now (free-tier per-minute limits). Try the segment again in a minute." }],
      isError: true
    })
  }
]
