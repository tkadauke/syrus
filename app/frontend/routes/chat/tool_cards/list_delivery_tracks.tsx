import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { Badge, CardShell, displayValue, EmptyState, EntityReference } from "../toolCardUi"

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
type DeliveryTracksResult = { repository: string; tracks: TrackRow[] }

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
  if (context.resultError) return null
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tracks)) return null
  const repository = displayValue(parsed.repository)
  if (!repository) return null
  return {
    repository,
    tracks: parsed.tracks.flatMap((item) => {
      const row = parseRow(item)
      return row ? [row] : []
    })
  }
}

function githubUrl(repository: string, branch?: string) {
  const repositoryPath = repository.split("/").map(encodeURIComponent).join("/")
  if (!branch) return `https://github.com/${repositoryPath}`
  return `https://github.com/${repositoryPath}/tree/${branch.split("/").map(encodeURIComponent).join("/")}`
}

function BranchLink({ branch, repository }: { branch: string | null; repository: string }) {
  if (!branch) return <>—</>
  return (
    <a
      className="font-mono font-medium text-brand hover:underline dark:text-brand-emphasis"
      href={githubUrl(repository, branch)}
      rel="noreferrer"
      target="_blank"
    >
      {branch}
    </a>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return `${result.tracks.length} delivery track${result.tracks.length === 1 ? "" : "s"} · ${result.repository}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const repositoryReference = <EntityReference href={githubUrl(result.repository)} kind="repository" repositorySlug={result.repository} wrap="break" />
  if (result.tracks.length === 0)
    return (
      <CardShell>
        <div>{repositoryReference}</div>
        <EmptyState>No delivery tracks configured.</EmptyState>
      </CardShell>
    )

  return (
    <CardShell>
      <div>{repositoryReference}</div>
      <Table responsive>
        <THead columns={["Track", "Branch", "Review phase", "Landing phase", "CI failure phase", "Branch health phase", "Sync after landing"]} />
        <TBody>
          {result.tracks.map((row) => (
            <tr key={row.name}>
              <Td mono primary>
                <span className="flex flex-wrap items-center gap-1">
                  {row.name}
                  {row.isDefault ? <Badge>default</Badge> : null}
                </span>
              </Td>
              <Td wrap>
                <BranchLink branch={row.branch} repository={result.repository} />
              </Td>
              <Td>{row.reviewGradePhase || "—"}</Td>
              <Td>{row.landingGradePhase || "—"}</Td>
              <Td>{row.ciFailureGradePhase || "—"}</Td>
              <Td>{row.branchHealthGradePhase || "—"}</Td>
              <Td wrap>
                <BranchLink branch={row.afterLandingSyncTo} repository={result.repository} />
              </Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

const listDeliveryTracksToolCard: ToolCardRenderer = { toolName: "list_delivery_tracks", collapsedSummary, renderExpanded }
export default listDeliveryTracksToolCard

export const examples: ToolCardExample[] = [
  {
    id: "multiple_tracks",
    label: "Multiple delivery tracks",
    parsedResult: {
      repository: "acme/widgets",
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
        },
        { name: "release", default: false, branch: "release/current" }
      ]
    }
  },
  { id: "empty", label: "No delivery tracks", parsedResult: { repository: "acme/widgets", tracks: [] } },
  { id: "error", label: "Repository unavailable", resultBody: "No repository attached.", resultError: true }
]
