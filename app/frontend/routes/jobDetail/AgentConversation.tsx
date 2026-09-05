import { useQuery } from "@tanstack/react-query"
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { GearIcon } from "../../components/GearIcon"
import { CloseIcon } from "../../components/CloseIcon"
import { StatusPill, TonePill } from "../../components/StatusPill"
import { fetchJobAgentConversation, fetchJobRunArtifacts, type AgentConversationEdge, type AgentConversationNode } from "../../api/jobs"
import { PanelMessage, RunTranscriptLogs } from "./components"

// "Agent Conversation" tab: a causal node/edge DAG of everything that fed
// into a Job's implementation -- agent sessions, deterministic checks
// (graders/format/generate/dependency_audit), and external triggers
// (PR/chat feedback, CI failures). Order only, no time axis; deliberately
// does not reuse worker_timeline's Gantt-style components. Reads the graph
// straight from GET /api/v1/app/jobs/:job_id/agent_conversation, which
// already resolves grader_fanout fan-out/fan-in and skip-through steps into
// plain node/edge pairs -- this file only has to lay that out and label it.

const ARROW_MARKER_ID = "agent-conversation-arrow"

export function AgentConversationTab({ jobId, prUrl, externalPrUrl }: { jobId: string; prUrl: string | null; externalPrUrl: string | null }) {
  const { t } = useT("jobs")
  const conversation = useQuery({
    queryKey: ["jobs", jobId, "agent_conversation"],
    queryFn: () => fetchJobAgentConversation(jobId)
  })
  const [openSession, setOpenSession] = useState<AgentConversationNode | null>(null)
  const [openCheck, setOpenCheck] = useState<AgentConversationNode | null>(null)

  if (conversation.isPending) return <PanelMessage>{t("conversation.loading")}</PanelMessage>
  if (conversation.isError) return <PanelMessage tone="error">{errorMessage(conversation.error, t("conversation.error"))}</PanelMessage>

  const { nodes, edges } = conversation.data
  if (nodes.length === 0) return <PanelMessage>{t("conversation.empty")}</PanelMessage>

  const segments = splitAgentConversationSegments(nodes, edges)

  return (
    <div className="space-y-6">
      <ConversationLegend />
      {segments.map((segment, index) => (
        <div className="space-y-3" key={segment.trigger?.id ?? `segment-${index}`}>
          {segment.trigger ? <TriggerBanner externalPrUrl={externalPrUrl} node={segment.trigger} prUrl={prUrl} /> : null}
          {segment.nodes.length > 0 ? (
            <ColumnGraph edges={segment.edges} nodes={segment.nodes} onOpenCheck={setOpenCheck} onOpenSession={setOpenSession} />
          ) : null}
        </div>
      ))}
      {openSession ? <SessionTranscriptDrawer jobId={jobId} node={openSession} onClose={() => setOpenSession(null)} /> : null}
      {openCheck ? <CheckDetailDrawer node={openCheck} onClose={() => setOpenCheck(null)} /> : null}
    </div>
  )
}

function ConversationLegend() {
  const { t } = useT("jobs")
  return (
    <div className="flex flex-wrap items-center gap-4 text-xs text-gray-500 dark:text-gray-400">
      <span className="flex items-center gap-1.5"><span aria-hidden="true" className="h-3 w-3 rounded-full bg-brand" />{t("conversation.legend_agent_session")}</span>
      <span className="flex items-center gap-1.5"><span aria-hidden="true" className="h-3 w-3 rounded border-2 border-dashed border-gray-400 dark:border-gray-500" />{t("conversation.legend_deterministic_check")}</span>
      <span className="flex items-center gap-1.5"><span aria-hidden="true" className="h-3 w-3 rounded border-2 border-dashed border-amber-400" />{t("conversation.legend_external_trigger")}</span>
    </div>
  )
}

// Segmenting + column layout are pure over the payload shape, so both are
// exported for unit testing independent of any DOM measurement.

export type AgentConversationSegment = {
  trigger: AgentConversationNode | null
  nodes: AgentConversationNode[]
  edges: AgentConversationEdge[]
}

export function splitAgentConversationSegments(nodes: AgentConversationNode[], edges: AgentConversationEdge[]): AgentConversationSegment[] {
  const segments: AgentConversationSegment[] = []
  let currentTrigger: AgentConversationNode | null = null
  let currentNodes: AgentConversationNode[] = []

  function flush() {
    if (currentTrigger || currentNodes.length > 0) {
      segments.push({ trigger: currentTrigger, nodes: currentNodes, edges: [] })
    }
    currentTrigger = null
    currentNodes = []
  }

  for (const node of nodes) {
    if (node.kind === "external_trigger") {
      flush()
      currentTrigger = node
    } else {
      currentNodes.push(node)
    }
  }
  flush()

  const segmentIndexById = new Map<string, number>()
  segments.forEach((segment, index) => {
    for (const node of segment.nodes) segmentIndexById.set(node.id, index)
  })
  for (const edge of edges) {
    const toSegment = segmentIndexById.get(edge.to_id)
    if (toSegment == null) continue
    if (segmentIndexById.get(edge.from_id) === toSegment) segments[toSegment].edges.push(edge)
  }

  return segments
}

// Rank = longest path from a root (a node with no in-segment predecessor).
// Nodes sharing a rank render in the same column -- which is exactly what
// makes grader_fanout's parallel graders line up side by side and their
// shared successor land one column over, with no fan-out-specific code.
export function computeAgentConversationColumns(nodes: AgentConversationNode[], edges: AgentConversationEdge[]): AgentConversationNode[][] {
  const ids = new Set(nodes.map((node) => node.id))
  const incoming = new Map<string, string[]>()
  for (const node of nodes) incoming.set(node.id, [])
  for (const edge of edges) {
    if (ids.has(edge.from_id) && ids.has(edge.to_id)) incoming.get(edge.to_id)?.push(edge.from_id)
  }

  const rank = new Map<string, number>()
  function rankOf(id: string, visiting: Set<string>): number {
    const cached = rank.get(id)
    if (cached != null) return cached
    if (visiting.has(id)) return 0

    visiting.add(id)
    const predecessors = incoming.get(id) ?? []
    const value = predecessors.length === 0 ? 0 : Math.max(...predecessors.map((p) => rankOf(p, visiting))) + 1
    rank.set(id, value)
    return value
  }
  for (const node of nodes) rankOf(node.id, new Set())

  const maxRank = nodes.reduce((max, node) => Math.max(max, rank.get(node.id) ?? 0), 0)
  const columns: AgentConversationNode[][] = Array.from({ length: maxRank + 1 }, () => [])
  for (const node of nodes) columns[rank.get(node.id) ?? 0].push(node)
  return columns
}

// Generates a short handoff description per edge from the node data on
// either end -- never hardcoded per example. Falls through to a generic
// "A -> B" description so every edge gets a label, per the spec.
export function agentConversationEdgeLabel(from: AgentConversationNode, to: AgentConversationNode, t: ReturnType<typeof useT>["t"]): string {
  const fromDetail = (from.detail ?? {}) as Record<string, unknown>
  const verdict = typeof fromDetail.verdict === "string" ? fromDetail.verdict : null
  const isReviewKind = from.step_kind === "adversarial_review" || from.step_kind === "visual_review"

  if (from.kind === "external_trigger") return t("conversation.edge_trigger_started", { trigger: from.label })
  if (from.kind === "agent_session" && isReviewKind && verdict) return t("conversation.edge_reviewer_replied", { reviewer: from.label, verdict })
  if (from.kind === "deterministic_check") {
    return from.state === "succeeded"
      ? t("conversation.edge_check_passed", { check: from.label })
      : t("conversation.edge_check_failed", { check: from.label })
  }
  if (from.kind === "agent_session" && to.kind === "deterministic_check") return t("conversation.edge_sent_for_check")
  if (from.kind === "agent_session" && to.kind === "agent_session" && (to.step_kind === "adversarial_review" || to.step_kind === "visual_review")) {
    return t("conversation.edge_sent_for_review")
  }

  return t("conversation.edge_default", { from: from.label, to: to.label })
}

type NodeRect = { x: number; y: number; w: number; h: number }

function ColumnGraph({ nodes, edges, onOpenSession, onOpenCheck }: { nodes: AgentConversationNode[]; edges: AgentConversationEdge[]; onOpenSession: (node: AgentConversationNode) => void; onOpenCheck: (node: AgentConversationNode) => void }) {
  const { t } = useT("jobs")
  const columns = useMemo(() => computeAgentConversationColumns(nodes, edges), [nodes, edges])
  const nodeById = useMemo(() => new Map(nodes.map((node) => [node.id, node])), [nodes])
  const containerRef = useRef<HTMLDivElement | null>(null)
  const nodeRefs = useRef(new Map<string, HTMLElement>())
  const [rects, setRects] = useState<Record<string, NodeRect>>({})

  const measure = useCallback(() => {
    const container = containerRef.current
    if (!container) return
    const containerRect = container.getBoundingClientRect()
    const next: Record<string, NodeRect> = {}
    nodeRefs.current.forEach((el, id) => {
      const rect = el.getBoundingClientRect()
      next[id] = { x: rect.left - containerRect.left, y: rect.top - containerRect.top, w: rect.width, h: rect.height }
    })
    setRects(next)
  }, [])

  useLayoutEffect(() => {
    measure()
    if (typeof ResizeObserver === "undefined") return undefined
    const observer = new ResizeObserver(() => measure())
    if (containerRef.current) observer.observe(containerRef.current)
    return () => observer.disconnect()
  }, [measure, columns])

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-gray-50/50 dark:border-gray-700 dark:bg-gray-950/30">
      <div className="relative p-6" ref={containerRef}>
        <svg aria-hidden="true" className="pointer-events-none absolute inset-0 h-full w-full overflow-visible">
          <defs>
            <marker id={ARROW_MARKER_ID} markerHeight="7" markerWidth="7" orient="auto-start-reverse" refX="6" refY="3.5" viewBox="0 0 10 10">
              <path className="fill-gray-400 dark:fill-gray-600" d="M0,0 L10,3.5 L0,7 Z" />
            </marker>
          </defs>
          {edges.map((edge) => {
            const from = rects[edge.from_id]
            const to = rects[edge.to_id]
            const fromNode = nodeById.get(edge.from_id)
            const toNode = nodeById.get(edge.to_id)
            if (!from || !to || !fromNode || !toNode) return null

            const x1 = from.x + from.w
            const y1 = from.y + from.h / 2
            const x2 = to.x
            const y2 = to.y + to.h / 2
            const midX = (x1 + x2) / 2
            const label = agentConversationEdgeLabel(fromNode, toNode, t)
            const labelX = (x1 + x2) / 2
            const labelY = (y1 + y2) / 2

            return (
              <g key={`${edge.from_id}->${edge.to_id}`}>
                <path
                  className="stroke-gray-300 dark:stroke-gray-700"
                  d={`M ${x1} ${y1} C ${midX} ${y1}, ${midX} ${y2}, ${x2} ${y2}`}
                  fill="none"
                  markerEnd={`url(#${ARROW_MARKER_ID})`}
                  strokeWidth={1.5}
                />
                {label ? (
                  <g transform={`translate(${labelX}, ${labelY})`}>
                    <rect className="fill-gray-50 dark:fill-gray-950" height={14} rx={3} width={Math.min(220, Math.max(24, label.length * 5.2))} x={-Math.min(220, Math.max(24, label.length * 5.2)) / 2} y={-16} />
                    <text className="fill-gray-500 text-[10px] dark:fill-gray-400" textAnchor="middle" y={-6}>{truncateEdgeLabel(label)}</text>
                  </g>
                ) : null}
              </g>
            )
          })}
        </svg>
        <div className="relative flex items-start gap-14">
          {columns.map((column, index) => (
            <div className="flex w-56 shrink-0 flex-col gap-6" key={index}>
              {column.map((node) => (
                <div
                  key={node.id}
                  ref={(el) => {
                    if (el) nodeRefs.current.set(node.id, el)
                    else nodeRefs.current.delete(node.id)
                  }}
                >
                  {node.kind === "agent_session" ? (
                    <AgentSessionNodeCard node={node} onOpen={() => onOpenSession(node)} />
                  ) : (
                    <DeterministicCheckNodeCard node={node} onOpen={() => onOpenCheck(node)} />
                  )}
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

function truncateEdgeLabel(label: string) {
  return label.length > 44 ? `${label.slice(0, 43)}…` : label
}

const ROLE_COLORS: Record<string, string> = {
  "workflow:implement": "bg-brand",
  "workflow:rebase_conflict": "bg-teal-600",
  "workflow:summary_test_plan": "bg-indigo-600",
  "workflow:adversarial_reviewer": "bg-rose-600",
  "workflow:visual_reviewer": "bg-pink-600",
  "workflow:manual": "bg-gray-500"
}

function roleColor(role: string | undefined) {
  return (role && ROLE_COLORS[role]) || "bg-gray-500"
}

function AgentSessionNodeCard({ node, onOpen }: { node: AgentConversationNode; onOpen: () => void }) {
  const { t } = useT("jobs")
  const detail = (node.detail ?? {}) as Record<string, unknown>
  const verdict = typeof detail.verdict === "string" ? detail.verdict : null

  return (
    <button className="flex w-full items-start gap-3 rounded-lg border border-gray-200 bg-white p-3 text-left shadow-sm hover:border-brand hover:shadow dark:border-gray-700 dark:bg-gray-900" onClick={onOpen} type="button">
      <span aria-hidden="true" className={`mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-white ${roleColor(node.role)}`}>
        {node.label.slice(0, 1).toUpperCase()}
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-center gap-1.5">
          <span className="text-sm font-medium text-gray-900 dark:text-gray-100">{node.label}</span>
          {node.state ? <StatusPill state={node.state} /> : null}
        </span>
        {verdict ? (
          <span className="mt-1 block">
            <TonePill tone={verdict === "needs_work" ? "red" : "green"}>{verdict}</TonePill>
          </span>
        ) : null}
        <span className="mt-1 block break-words text-xs text-gray-600 dark:text-gray-300">{node.summary || t("conversation.no_summary")}</span>
      </span>
    </button>
  )
}

function DeterministicCheckNodeCard({ node, onOpen }: { node: AgentConversationNode; onOpen: () => void }) {
  const failed = node.state != null && !["succeeded", "skipped"].includes(node.state)
  return (
    <button
      className={`flex w-full items-start gap-2 rounded-lg border-2 border-dashed p-3 text-left ${failed ? "border-red-300 bg-red-50 dark:border-red-800 dark:bg-red-950/30" : "border-gray-300 bg-gray-100/70 dark:border-gray-600 dark:bg-gray-800/60"}`}
      onClick={onOpen}
      type="button"
    >
      <GearIcon className="mt-0.5 h-5 w-5 shrink-0 text-gray-500 dark:text-gray-400" />
      <span className="min-w-0 flex-1">
        <span className="flex flex-wrap items-center gap-1.5">
          <span className="text-sm font-medium text-gray-800 dark:text-gray-100">{node.label}</span>
          {node.state ? <StatusPill state={node.state} /> : null}
        </span>
        {node.summary ? <span className="mt-1 block break-words text-xs text-gray-600 dark:text-gray-300">{node.summary}</span> : null}
      </span>
    </button>
  )
}

function triggerHref(node: AgentConversationNode, prUrl: string | null, externalPrUrl: string | null): string | null {
  const detail = node.detail as Record<string, unknown> | null
  if (!detail) return null

  if (node.trigger_kind === "pr_comment") {
    const comments = Array.isArray(detail.comments) ? (detail.comments as Array<Record<string, unknown>>) : []
    const latest = comments.at(-1)
    const base = prUrl || externalPrUrl
    if (!latest || !base || latest.id == null) return null
    const anchor = latest.path != null ? `discussion_r${latest.id}` : `issuecomment-${latest.id}`
    return `${base}#${anchor}`
  }

  if (node.trigger_kind === "ci_failure") {
    const checks = Array.isArray(detail.failed_checks) ? (detail.failed_checks as Array<Record<string, unknown>>) : []
    const withUrl = checks.find((check) => typeof check.html_url === "string")
    return typeof withUrl?.html_url === "string" ? withUrl.html_url : null
  }

  return null
}

function TriggerBanner({ node, prUrl, externalPrUrl }: { node: AgentConversationNode; prUrl: string | null; externalPrUrl: string | null }) {
  const { t } = useT("jobs")
  const href = triggerHref(node, prUrl, externalPrUrl)

  return (
    <div className="w-full rounded-lg border-2 border-dashed border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-950/30 dark:text-amber-100">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-semibold">{node.label}</span>
        {href ? (
          <a className="text-xs font-medium underline hover:no-underline" href={href} rel="noopener" target="_blank">
            {t("conversation.view_source")}
          </a>
        ) : null}
      </div>
      {node.summary ? <p className="mt-1">{node.summary}</p> : null}
    </div>
  )
}

function DrawerHeader({ title, onClose }: { title: string; onClose: () => void }) {
  const { t } = useT("jobs")
  return (
    <div className="flex items-center justify-between gap-3 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
      <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{title}</h3>
      <button aria-label={t("conversation.close")} className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
        <CloseIcon className="h-4 w-4" />
      </button>
    </div>
  )
}

// Opens the same transcript view the agent_activity sessions feed uses,
// keyed off the node's run_id -- the standard per-run artifacts endpoint,
// not a new one.
function SessionTranscriptDrawer({ jobId, node, onClose }: { jobId: string; node: AgentConversationNode; onClose: () => void }) {
  const { t } = useT("jobs")
  const runId = node.run_id
  const transcript = useQuery({
    queryKey: ["jobs", jobId, "agent_conversation_transcript", runId],
    queryFn: () => fetchJobRunArtifacts(`/api/v1/app/jobs/${jobId}/runs/${runId}/artifacts`),
    enabled: runId != null
  })

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <DrawerHeader onClose={onClose} title={`${node.label} — ${t("conversation.transcript_heading")}`} />
      {node.summary ? <p className="border-b border-gray-100 px-3 py-2 text-sm text-gray-700 dark:border-gray-800 dark:text-gray-300">{node.summary}</p> : null}
      {transcript.isPending ? <p className="p-3 text-sm text-gray-500 dark:text-gray-400">{t("conversation.transcript_loading")}</p> : null}
      {transcript.isError ? <p className="p-3 text-sm text-red-700 dark:text-red-300">{errorMessage(transcript.error, t("conversation.transcript_error"))}</p> : null}
      {transcript.data ? (
        transcript.data.logs.length > 0 ? <RunTranscriptLogs logs={transcript.data.logs} /> : <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("conversation.no_transcript")}</p>
      ) : null}
    </section>
  )
}

// Deterministic checks never get the reviewing-agent's "reasoning" framing
// -- just whatever raw data the graph payload already carries for that
// check kind (grader command/output, format/generate failures, dependency
// audit results). No extra network call: it's all already in node.detail.
function CheckDetailDrawer({ node, onClose }: { node: AgentConversationNode; onClose: () => void }) {
  const { t } = useT("jobs")
  const detail = (node.detail ?? {}) as Record<string, unknown>
  const failures = (detail.format_failures ?? detail.generate_failures) as Array<Record<string, unknown>> | undefined
  const auditResults = node.step_kind === "dependency_audit" ? (detail.results as Array<Record<string, unknown>> | undefined) : undefined
  const hasOutput = typeof detail.output === "string" && detail.output.length > 0
  const hasNothing = !hasOutput && !detail.command && !failures?.length && !auditResults?.length

  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <DrawerHeader onClose={onClose} title={node.label} />
      {(typeof detail.command === "string" || typeof detail.exit_code === "number" || typeof detail.duration_s === "number") ? (
        <dl className="grid grid-cols-1 gap-x-4 gap-y-1 px-3 py-2 text-xs text-gray-600 sm:grid-cols-2 dark:text-gray-300">
          {typeof detail.command === "string" ? <DetailRow label={t("conversation.check_command")} mono value={detail.command} /> : null}
          {typeof detail.exit_code === "number" ? <DetailRow label={t("conversation.check_exit_code")} value={String(detail.exit_code)} /> : null}
          {typeof detail.duration_s === "number" ? <DetailRow label={t("conversation.check_duration")} value={`${detail.duration_s}s`} /> : null}
        </dl>
      ) : null}
      {hasOutput ? (
        <pre className="max-h-[28rem] overflow-auto whitespace-pre-wrap break-words border-t border-gray-100 p-3 font-mono text-xs text-gray-800 dark:border-gray-800 dark:text-gray-200">{detail.output as string}</pre>
      ) : null}
      {failures?.length ? (
        <div className="space-y-3 border-t border-gray-100 p-3 dark:border-gray-800">
          {failures.map((failure, index) => (
            <div className="rounded border border-red-200 bg-red-50 p-2 dark:border-red-900/60 dark:bg-red-950/30" key={index}>
              <code className="block break-all text-xs text-red-900 dark:text-red-200">{String(failure.command)}</code>
              {failure.output_tail ? <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap break-words text-xs text-red-800 dark:text-red-300">{String(failure.output_tail)}</pre> : null}
            </div>
          ))}
        </div>
      ) : null}
      {auditResults?.length ? (
        <ul className="space-y-1 border-t border-gray-100 p-3 text-xs text-gray-700 dark:border-gray-800 dark:text-gray-300">
          {auditResults.map((result, index) => (
            <li key={index}>{String(result.ecosystem ?? result.name ?? index)}: {result.clean ? t("conversation.check_clean") : t("conversation.check_flagged")}</li>
          ))}
        </ul>
      ) : null}
      {hasNothing ? <p className="p-3 text-sm text-gray-400 dark:text-gray-500">{t("conversation.check_no_output")}</p> : null}
    </section>
  )
}

function DetailRow({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <dt className="text-gray-400 dark:text-gray-500">{label}</dt>
      <dd className={`truncate ${mono ? "font-mono" : ""}`} title={value}>{value}</dd>
    </div>
  )
}
