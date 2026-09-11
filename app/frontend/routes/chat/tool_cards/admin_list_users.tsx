import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, numberValue, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_list_users (the tool-card work). Renders
// the full user roster as a dense table: account flags, agent provider,
// scheduling state, and Job count.
type UserRow = {
  key: string
  id: string
  email: string | null
  admin: boolean
  agentProvider: string | null
  schedulingPaused: boolean
  createdAt: string | null
  jobCount: number | null
}

function parseRow(value: unknown, index: number): UserRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    key: `${id}-${index}`,
    id,
    email: displayValue(value.email),
    admin: value.admin === true,
    agentProvider: displayValue(value.agent_provider),
    schedulingPaused: value.scheduling_paused === true,
    createdAt: displayValue(value.created_at),
    jobCount: numberValue(value.job_count)
  }
}

function userRows(context: ToolCardContext): UserRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.users)) return null

  return parsed.users.flatMap((user, index) => {
    const row = parseRow(user, index)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = userRows(context)
  if (!rows) return null
  return `${rows.length} user${rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const rows = userRows(context)
  if (!rows) return null

  if (rows.length === 0) return <EmptyState>No users found.</EmptyState>

  return (
    <CardShell>
      <Table>
        <THead columns={["Email", "Admin", "Provider", "Scheduling", "Created", "Jobs"]} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td maxWidth title={row.email ?? undefined}>
                {row.email || "—"}
              </Td>
              <Td>{row.admin ? <Badge>admin</Badge> : "—"}</Td>
              <Td>{row.agentProvider || "—"}</Td>
              <Td>{row.schedulingPaused ? <StatePill state="paused" tone="warning" /> : <StatePill state="active" tone="success" />}</Td>
              <Td mono>{row.createdAt || "—"}</Td>
              <Td mono>{row.jobCount ?? "—"}</Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const adminListUsersToolCard: ToolCardRenderer = {
  toolName: "admin_list_users",
  collapsedSummary,
  renderExpanded
}

export default adminListUsersToolCard
