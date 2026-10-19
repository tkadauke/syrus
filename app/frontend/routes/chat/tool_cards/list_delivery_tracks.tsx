import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { Badge, displayValue, EmptyState, EntityReference } from "../toolCardUi"

// Core-owned tool card for list_delivery_tracks (the tool-card work).
type TrackRow = {
  name: string
  isDefault: boolean
  branch: string | null
  reviewGradePhase: string | null
  landingGradePhase: string | null
  ciFailureGradePhase: string | null
  branchHealthGradePhase: string | null
  afterLandingSyncTo: string | null
}

type DeliveryTracksResult = { repository: string | null; rows: TrackRow[] }

function parseRow(value: unknown): TrackRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null

  return {
    name,
    isDefault: value.default === true,
    branch: displayValue(value.branch),
    reviewGradePhase: displayValue(value.review_grade_phase),
    landingGradePhase: displayValue(value.landing_grade_phase),
    ciFailureGradePhase: displayValue(value.ci_failure_grade_phase),
    branchHealthGradePhase: displayValue(value.branch_health_grade_phase),
    afterLandingSyncTo: displayValue(value.after_landing_sync_to)
  }
}

function parseResult(context: ToolCardContext): DeliveryTracksResult | null {
  const parsed = context.parsedResult
  if (context.resultError || !isPlainObject(parsed) || !Array.isArray(parsed.tracks)) return null

  return {
    repository: displayValue(parsed.repository),
    rows: parsed.tracks.flatMap((item) => {
      const row = parseRow(item)
      return row ? [row] : []
    })
  }
}

function githubUrl(repository: string, path = "") {
  return `https://github.com/${repository}${path}`
}

function BranchReference({ branch, repository }: { branch: string | null; repository: string | null }) {
  if (!branch) return <>—</>
  if (!repository) return <span className="font-mono">{branch}</span>
  return (
    <a
      className="font-mono font-medium text-brand hover:underline dark:text-brand-emphasis"
      href={githubUrl(repository, `/tree/${encodeURIComponent(branch)}`)}
    >
      {branch}
    </a>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return `${result.rows.length} delivery track${result.rows.length === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <div className="space-y-2">
      {result.repository ? (
        <div className="text-xs text-text-muted">
          Repository: <EntityReference href={githubUrl(result.repository)} kind="repository" repositorySlug={result.repository} wrap="nowrap" />
        </div>
      ) : null}
      {result.rows.length === 0 ? (
        <EmptyState>No delivery tracks configured.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["Track", "Branch", "Review phase", "Landing phase", "CI failure phase", "Branch health phase", "After landing sync"]} />
          <TBody>
            {result.rows.map((row) => (
              <tr key={row.name}>
                <Td mono primary>
                  <span className="flex flex-wrap items-center gap-1">
                    {row.name}
                    {row.isDefault ? <Badge>default</Badge> : null}
                  </span>
                </Td>
                <Td>
                  <BranchReference branch={row.branch} repository={result.repository} />
                </Td>
                <Td>{row.reviewGradePhase || "—"}</Td>
                <Td>{row.landingGradePhase || "—"}</Td>
                <Td>{row.ciFailureGradePhase || "—"}</Td>
                <Td>{row.branchHealthGradePhase || "—"}</Td>
                <Td>
                  <BranchReference branch={row.afterLandingSyncTo} repository={result.repository} />
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  )
}

const listDeliveryTracksToolCard: ToolCardRenderer = {
  toolName: "list_delivery_tracks",
  collapsedSummary,
  renderExpanded
}

export default listDeliveryTracksToolCard

export const examples: ToolCardExample[] = [
  {
    id: "all_delivery_phases",
    label: "All delivery phases and branch links",
    parsedResult: {
      repository: "tkadauke/syrus",
      tracks: [
        {
          name: "default",
          default: true,
          branch: "main",
          review_grade_phase: "review",
          landing_grade_phase: "landing",
          ci_failure_grade_phase: "ci_failure",
          branch_health_grade_phase: "branch_health",
          after_landing_sync_to: "develop"
        }
      ]
    }
  },
  {
    id: "no_delivery_tracks",
    label: "No delivery tracks",
    description: "The attached repository has no configured delivery tracks.",
    parsedResult: { repository: "tkadauke/syrus", tracks: [] }
  }
]
