import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, Row, StatePill } from "../toolCardUi"
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

  const requestedLimit = numberValue(context.input?.limit)

  return (
    <CardShell>
      <Row label="Requested limit" value={requestedLimit == null ? "20 (default)" : String(requestedLimit)} />
      {rows.length === 0 ? (
        <EmptyState>No users found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["ID", "Email", "Admin", "Provider", "Scheduling", "Created", "Jobs"]} />
          <TBody>
            {rows.map((row) => (
              <tr key={row.key}>
                <Td mono primary>
                  <EntityReference id={row.id} kind="artifact" />
                </Td>
                <Td maxWidth title={row.email ?? undefined} wrap>
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
      )}
    </CardShell>
  )
}

const adminListUsersToolCard: ToolCardRenderer = {
  toolName: "admin_list_users",
  collapsedSummary,
  renderExpanded
}

export default adminListUsersToolCard

export const examples = [
  {
    id: "users_with_account_details",
    label: "Users with account details",
    input: { limit: 20 },
    parsedResult: {
      users: [
        {
          id: 7,
          email: "operator-with-a-long-address@example.com",
          admin: true,
          agent_provider: "codex",
          scheduling_paused: false,
          created_at: "2026-01-01T00:00:00Z",
          job_count: 12
        }
      ]
    }
  },
  {
    id: "no_users",
    label: "No users",
    input: { limit: 20 },
    parsedResult: { users: [] }
  }
]
