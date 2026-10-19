import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { DataTable } from "../../components/ui"
import { Table, TBody, Td, THead } from "./adminToolCard"
import { MarkdownPreview } from "./toolCardMarkdown"
import { EmptyState, EntityReference, StatePill } from "./toolCardUi"

// Shared dense-table rendering for the list_jobs and search_jobs tool cards
// (the Tier 1 tool-card work) — both tools return arrays of similarly-shaped Job
// summaries, so the table markup and row parsing live here instead of being
// duplicated across the two `tool_cards/*.tsx` files. This file intentionally
// does NOT live under `tool_cards/` itself: pluginToolCards.tsx's directory
// glob treats every non-test .tsx file there as a card module and would warn
// about a missing default export.
export type JobRow = {
  key: string
  jobId: string
  title: string
  state: string
  repositorySlug: string | null
  prNumber: string | null
  priority: string | null
  kind: string | null
  issueNumber: string | null
  branchName: string | null
  closureReason: string | null
  agentProvider: string | null
  jobProviderSetting: string | null
  goalId: string | null
  createdAt: string | null
  updatedAt: string | null
}

function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

export function parseJobRow(value: unknown): JobRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    jobId: `JOB-${id}`,
    title: displayValue(value.issue_title) || `JOB-${id}`,
    state,
    repositorySlug: displayValue(value.repository_slug),
    prNumber: displayValue(value.pr_number),
    priority: displayValue(value.priority),
    kind: displayValue(value.kind),
    issueNumber: displayValue(value.issue_number),
    branchName: displayValue(value.branch_name),
    closureReason: displayValue(value.closure_reason),
    agentProvider: displayValue(value.agent_provider),
    jobProviderSetting: displayValue(value.job_provider_setting),
    goalId: isPlainObject(value.goal_provenance) ? displayValue(value.goal_provenance.chat_goal_id) : null,
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at)
  }
}

function parseJson(value: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    return null
  }
}

export function jobResult(context: ToolCardContext, key: "jobs" | "results"): unknown[] | null {
  let value = context.parsedResult
  if (isPlainObject(value) && value.structured_content != null) value = value.structured_content
  if (isPlainObject(value) && Array.isArray(value.content)) {
    const first = value.content[0]
    if (isPlainObject(first) && typeof first.text === "string") value = parseJson(first.text)
  }
  if (Array.isArray(value)) return value
  return isPlainObject(value) && Array.isArray(value[key]) ? value[key] : null
}

export function resultErrorMessage(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  if (typeof context.parsedResult === "string") return context.parsedResult
  if (isPlainObject(context.parsedResult)) return displayValue(context.parsedResult.error) || displayValue(context.parsedResult.message) || context.resultBody
  return context.resultBody || "The Jobs request failed."
}

function githubUrl(slug: string, suffix = "") {
  const path = slug.split("/").filter(Boolean).map(encodeURIComponent).join("/")
  return path ? `https://github.com/${path}${suffix}` : null
}

function detail(label: string, value: string | null) {
  return value ? (
    <div>
      <span className="text-text-subtle">{label}: </span>
      {value}
    </div>
  ) : null
}

export function JobsTable({ rows, emptyMessage }: { rows: JobRow[]; emptyMessage: string }) {
  if (rows.length === 0) {
    return <EmptyState>{emptyMessage}</EmptyState>
  }

  return (
    <Table responsive>
      <THead columns={["Job", "Title", "State", "Repository", "Source", "Execution", "Lifecycle"]} />
      <TBody>
        {rows.map((row) => (
          <DataTable.Row key={row.key}>
            <Td>
              <EntityReference id={row.key} kind="job" />
            </Td>
            <Td maxWidth wrap>
              <MarkdownPreview maxLines={3} text={row.title} />
            </Td>
            <Td wrap>
              <StatePill state={row.state} />
              {row.closureReason ? <div className="mt-1 text-text-muted">{row.closureReason}</div> : null}
            </Td>
            <Td wrap>
              {row.repositorySlug ? <EntityReference href={githubUrl(row.repositorySlug)} kind="repository" repositorySlug={row.repositorySlug} /> : "—"}
            </Td>
            <Td wrap>
              {detail("Kind", row.kind)}
              {detail("Issue", row.issueNumber ? `#${row.issueNumber}` : null)}
              {row.prNumber ? (
                <div>
                  <EntityReference
                    id={row.prNumber}
                    kind="pull_request"
                    prUrl={row.repositorySlug ? githubUrl(row.repositorySlug, `/pull/${encodeURIComponent(row.prNumber)}`) : null}
                  />
                </div>
              ) : null}
              {row.branchName && row.repositorySlug ? (
                <div>
                  <span className="text-text-subtle">Branch: </span>
                  <EntityReference
                    href={githubUrl(row.repositorySlug, `/tree/${encodeURIComponent(row.branchName)}`)}
                    kind="repository"
                    label={row.branchName}
                    slug={row.branchName}
                  />
                </div>
              ) : (
                detail("Branch", row.branchName)
              )}
            </Td>
            <Td wrap>
              {detail("Priority", row.priority)}
              {detail("Agent", row.agentProvider)}
              {detail("Setting", row.jobProviderSetting)}
              {detail("Goal", row.goalId ? `#${row.goalId}` : null)}
            </Td>
            <Td wrap>
              {detail("Created", row.createdAt)}
              {detail("Updated", row.updatedAt)}
            </Td>
          </DataTable.Row>
        ))}
      </TBody>
    </Table>
  )
}
