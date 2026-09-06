import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { StatusPill } from "../../components/StatusPill"
import { CloseIcon } from "../../components/CloseIcon"
import type { AgentConversationNode } from "../../api/jobs"
import { fetchJobAgentConversation, fetchJobRunArtifacts } from "../../api/jobs"
import { PanelMessage, RunTranscriptLogs, SmallPill } from "./components"
import {
  avatarColorClass,
  buildConversationRows,
  connectorLabel,
  deterministicCommandLine,
  deterministicRawOutput,
  externalTriggerContent,
  externalTriggerSourceUrl
} from "./agentConversationGraph"

// The Agent Conversation tab: a causal node/edge graph of everything that fed
// into a Job's implementation -- who said what to whom, in order. Rendered as
// a single vertical thread, narrow and centered (like a chat) rather than
// stretched across the full Job Detail page width, so a connector's handoff
// label reads as one flow top-to-bottom instead of scattered wide cards. An
// external_trigger banner spans the full width of that thread column, and a
// grader_fanout's parallel checks lay out side by side within one row.

export function AgentConversationTab({ jobId, prUrl }: { jobId: number; prUrl: string | null }) {
  const { t } = useT("jobs")
  const [transcriptNodeId, setTranscriptNodeId] = useState<string | null>(null)
  const conversation = useQuery({
    queryKey: ["jobs", String(jobId), "agent_conversation"],
    queryFn: () => fetchJobAgentConversation(jobId)
  })

  if (conversation.isPending) return <PanelMessage>{t("conversation_loading")}</PanelMessage>
  if (conversation.isError) return <PanelMessage tone="error">{errorMessage(conversation.error, t("conversation_load_error"))}</PanelMessage>
  if (conversation.data.nodes.length === 0) return <PanelMessage>{t("conversation_empty")}</PanelMessage>

  const rows = buildConversationRows(conversation.data.nodes, conversation.data.edges)
  const transcriptNode = conversation.data.nodes.find((node) => node.id === transcriptNodeId) ?? null

  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <ConversationLegend />
      <ol className="space-y-0">
        {rows.map((row, index) => (
          <li key={row.map((node) => node.id).join(",")}>
            {index > 0 ? <ConnectorLabel text={connectorLabel(rows[index - 1], row)} /> : null}
            <div className="flex flex-wrap items-stretch gap-3">
              {row.map((node) => (
                <NodeCard
                  jobId={jobId}
                  key={node.id}
                  node={node}
                  onOpenTranscript={setTranscriptNodeId}
                  prUrl={prUrl}
                  transcriptOpen={node.id === transcriptNodeId}
                />
              ))}
            </div>
          </li>
        ))}
      </ol>
      <TranscriptSidebar jobId={jobId} node={transcriptNode} onClose={() => setTranscriptNodeId(null)} />
    </div>
  )
}

function ConversationLegend() {
  const { t } = useT("jobs")
  return (
    <div className="flex flex-wrap items-center gap-x-5 gap-y-2 rounded border border-gray-200 bg-white px-3 py-2 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
      <span className="flex items-center gap-1.5">
        <span aria-hidden="true" className="h-3 w-3 rounded-full bg-brand" />
        {t("conversation_legend_agent_session")}
      </span>
      <span className="flex items-center gap-1.5">
        <span aria-hidden="true" className="h-3 w-3 rounded border border-dashed border-gray-400 dark:border-gray-500" />
        {t("conversation_legend_deterministic_check")}
      </span>
      <span className="flex items-center gap-1.5">
        <span aria-hidden="true" className="h-2.5 w-6 rounded-sm border border-dashed border-gray-400 dark:border-gray-500" />
        {t("conversation_legend_external_trigger")}
      </span>
    </div>
  )
}

// Rendered in normal document flow, not absolutely positioned at a fixed
// column gap -- the label wraps to however much height it needs, so a long
// generated handoff description never overlaps the node cards around it.
function ConnectorLabel({ text }: { text: string }) {
  return (
    <div className="ml-4 border-l-2 border-dotted border-gray-300 py-2 pl-4 text-xs text-gray-500 dark:border-gray-600 dark:text-gray-400">
      {text}
    </div>
  )
}

function NodeCard({
  node,
  jobId,
  prUrl,
  onOpenTranscript,
  transcriptOpen
}: {
  node: AgentConversationNode
  jobId: number
  prUrl: string | null
  onOpenTranscript: (nodeId: string) => void
  transcriptOpen: boolean
}) {
  if (node.kind === "agent_session") return <AgentSessionCard node={node} onOpenTranscript={onOpenTranscript} transcriptOpen={transcriptOpen} />
  if (node.kind === "deterministic_check") return <DeterministicCheckCard node={node} />
  return <ExternalTriggerBanner node={node} prUrl={prUrl} />
}

// Clicking a session no longer expands its transcript inline -- it opens the
// shared TranscriptSidebar on the right, mirroring the chat workspace's
// hidden-by-default side panel (see WorkspacePanels.tsx).
function AgentSessionCard({ node, onOpenTranscript, transcriptOpen }: { node: AgentConversationNode; onOpenTranscript: (nodeId: string) => void; transcriptOpen: boolean }) {
  const { t } = useT("jobs")

  return (
    <div className={`min-w-64 flex-1 rounded border bg-white dark:bg-gray-900 ${transcriptOpen ? "border-brand" : "border-gray-200 dark:border-gray-700"}`}>
      <button aria-expanded={transcriptOpen} className="flex w-full items-start gap-3 p-3 text-left" onClick={() => onOpenTranscript(node.id)} type="button">
        <span aria-hidden="true" className={`mt-0.5 h-8 w-8 shrink-0 rounded-full ${avatarColorClass(node.role)}`} />
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-gray-900 dark:text-gray-100">{node.label}</span>
            {node.state ? <StatusPill state={node.state} /> : null}
            {node.iteration && node.iteration > 1 ? <SmallPill>{t("conversation_iteration", { n: node.iteration })}</SmallPill> : null}
          </span>
          <span className="mt-1 block text-xs text-gray-600 dark:text-gray-400">{node.summary || t("conversation_no_summary")}</span>
        </span>
      </button>
    </div>
  )
}

// Hidden by default; shown on the right when an agent_session node is
// clicked, dismissed via the X button or the backdrop click.
function TranscriptSidebar({ jobId, node, onClose }: { jobId: number; node: AgentConversationNode | null; onClose: () => void }) {
  const { t } = useT("jobs")
  const artifactsPath = node?.run_id != null ? `/api/v1/app/jobs/${jobId}/runs/${node.run_id}/artifacts` : null
  const transcript = useQuery({
    queryKey: ["job_run_artifacts", String(jobId), String(node?.run_id)],
    queryFn: () => fetchJobRunArtifacts(artifactsPath as string),
    enabled: node != null && artifactsPath != null
  })

  if (!node) return null

  return (
    <>
      <div aria-hidden="true" className="fixed inset-0 z-30 bg-black/20" onClick={onClose} />
      <aside aria-label={t("conversation_transcript_panel_label", { label: node.label })} className="fixed inset-y-0 right-0 z-40 flex w-full max-w-md flex-col border-l border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-900">
        <div className="flex shrink-0 items-center justify-between gap-2 border-b border-gray-200 p-3 dark:border-gray-700">
          <h2 className="min-w-0 truncate text-sm font-semibold text-gray-900 dark:text-gray-100">{node.label}</h2>
          <button
            aria-label={t("conversation_transcript_close")}
            className="shrink-0 rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-300"
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
          {transcript.isPending ? <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">{t("run_loading")}</p> : null}
          {transcript.isError ? <p className="px-3 py-2 text-xs text-red-700 dark:text-red-300">{errorMessage(transcript.error, t("run_artifacts_error"))}</p> : null}
          {transcript.data ? (
            transcript.data.logs.length > 0 ? (
              <RunTranscriptLogs logs={transcript.data.logs} />
            ) : (
              <p className="px-3 py-2 text-xs text-gray-400 dark:text-gray-500">{t("artifact_no_transcript")}</p>
            )
          ) : null}
        </div>
      </aside>
    </>
  )
}

function DeterministicCheckCard({ node }: { node: AgentConversationNode }) {
  const { t } = useT("jobs")
  const [expanded, setExpanded] = useState(false)
  const output = deterministicRawOutput(node)
  const command = deterministicCommandLine(node)
  const iconTone = node.state === "failed"
    ? "text-red-600 dark:text-red-400"
    : node.state === "succeeded"
      ? "text-emerald-600 dark:text-emerald-400"
      : "text-gray-500 dark:text-gray-400"

  return (
    <div className="min-w-64 flex-1 rounded border border-dashed border-gray-400 bg-gray-50 dark:border-gray-600 dark:bg-gray-800/60">
      <button aria-expanded={expanded} className="flex w-full items-start gap-3 p-3 text-left" onClick={() => setExpanded((current) => !current)} type="button">
        <GearIcon className={`mt-0.5 h-6 w-6 shrink-0 ${iconTone}`} />
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-gray-900 dark:text-gray-100">{node.label}</span>
            {node.state ? <StatusPill state={node.state} /> : null}
          </span>
          <span className="mt-1 block text-xs text-gray-600 dark:text-gray-400">{node.summary || t("conversation_check_ran")}</span>
        </span>
      </button>
      {expanded ? (
        <div className="border-t border-dashed border-gray-400 p-3 dark:border-gray-600">
          {command ? <pre className="mb-2 overflow-x-auto rounded bg-white p-2 font-mono text-2xs text-gray-700 dark:bg-gray-950 dark:text-gray-300">$ {command}</pre> : null}
          {output ? (
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap rounded bg-white p-2 font-mono text-2xs text-gray-700 dark:bg-gray-950 dark:text-gray-300">{output}</pre>
          ) : (
            <p className="text-xs text-gray-400 dark:text-gray-500">{t("conversation_no_raw_output")}</p>
          )}
        </div>
      ) : null}
    </div>
  )
}

function ExternalTriggerBanner({ node, prUrl }: { node: AgentConversationNode; prUrl: string | null }) {
  const { t } = useT("jobs")
  const content = externalTriggerContent(node)
  const sourceUrl = externalTriggerSourceUrl(node, prUrl)

  return (
    <div className="w-full rounded border border-dashed border-gray-400 bg-amber-50/40 p-3 dark:border-gray-600 dark:bg-amber-950/10">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-semibold text-gray-900 dark:text-gray-100">{node.label}</span>
        {sourceUrl ? (
          <a className="text-xs font-medium text-brand hover:underline" href={sourceUrl} rel="noreferrer" target="_blank">
            {t("conversation_view_source")}
          </a>
        ) : null}
      </div>
      {content ? <p className="mt-1 whitespace-pre-wrap text-xs text-gray-700 dark:text-gray-300">{content}</p> : null}
    </div>
  )
}

function GearIcon({ className }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" viewBox="0 0 24 24">
      <path d="M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z" />
      <path d="M19.4 13.5a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V19.4a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H4.6a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H10.5a1.65 1.65 0 0 0 1-1.51V4.6a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V10.5a1.65 1.65 0 0 0 1.51 1H19.4a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z" />
    </svg>
  )
}
