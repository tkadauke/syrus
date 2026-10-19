import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Surface } from "../../../components/ui"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type RepositoryRow = {
  id: string
  slug: string
  owner: string | null
  name: string | null
  defaultBranch: string | null
  epicDependencyPolicy: string | null
  createdAt: string | null
  url: string | null
}
type ListRepositoriesResult = {
  rows: RepositoryRow[]
  page: number | null
  perPage: number | null
  totalPages: number | null
  totalCount: number | null
  hasNextPage: boolean | null
}

const failureConfig: ToolFailureConfig = {
  title: "Repository list",
  attempted: (context) => {
    const page = stringFromInput(context, ["page"])
    const perPage = stringFromInput(context, ["per_page"])
    return [page ? `page ${page}` : null, perPage ? `${perPage} per page` : null].filter(Boolean).join(", ") || "List repositories"
  },
  retrySafety: "safe",
  recovery: "Retry after checking repository access and the requested page."
}

function parseRow(value: unknown): RepositoryRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  if (!id || !slug) return null
  return {
    id,
    slug,
    owner: displayValue(value.owner),
    name: displayValue(value.name),
    defaultBranch: displayValue(value.default_branch),
    epicDependencyPolicy: displayValue(value.epic_dependency_policy),
    createdAt: displayValue(value.created_at),
    url: displayValue(value.github_url) ?? displayValue(value.html_url) ?? displayValue(value.url)
  }
}

function numberField(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseResult(context: ToolCardContext): ListRepositoriesResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.repositories)) return null
  const rows = parsed.repositories.flatMap((item) => {
    const row = parseRow(item)
    return row ? [row] : []
  })
  const pagination = isPlainObject(parsed.pagination) ? parsed.pagination : {}
  return {
    rows,
    page: numberField(pagination.page),
    perPage: numberField(pagination.per_page),
    totalPages: numberField(pagination.total_pages),
    totalCount: numberField(pagination.total_count),
    hasNextPage: typeof pagination.has_next_page === "boolean" ? pagination.has_next_page : null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  const result = parseResult(context)
  if (!result) return null
  const count = result.totalCount ?? result.rows.length
  return count === 0 ? "No repositories" : `${count} repositor${count === 1 ? "y" : "ies"}`
}

function RepositoryLink({ row }: { row: RepositoryRow }) {
  return <EntityReference href={row.url} kind="repository" repositoryId={row.id} repositorySlug={row.slug} slug={row.slug} />
}

function PaginationSummary({ result }: { result: ListRepositoriesResult }) {
  const parts = [
    result.page != null ? `Page ${result.page}${result.totalPages != null ? ` of ${result.totalPages}` : ""}` : null,
    result.perPage != null ? `${result.perPage} per page` : null,
    result.totalCount != null ? `${result.totalCount} total` : null,
    result.hasNextPage != null ? (result.hasNextPage ? "More pages available" : "Last page") : null
  ].filter(Boolean)
  return parts.length > 0 ? <div className="text-2xs text-gray-500 dark:text-gray-400">{parts.join(" · ")}</div> : null
}

function InputSummary({ context }: { context: ToolCardContext }) {
  const page = stringFromInput(context, ["page"])
  const perPage = stringFromInput(context, ["per_page"])
  if (!page && !perPage) return null
  return (
    <div className="break-words text-2xs text-gray-500 dark:text-gray-400">
      Requested: {[page ? `page ${page}` : null, perPage ? `${perPage} per page` : null].filter(Boolean).join(" · ")}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const result = parseResult(context)
  if (!result) return null
  return (
    <div className="mt-1 min-w-0 space-y-2">
      <InputSummary context={context} />
      {result.rows.length === 0 ? (
        <EmptyState>No repositories found.</EmptyState>
      ) : (
        <>
          <div className="space-y-2 sm:hidden">
            {result.rows.map((row) => (
              <Surface className="min-w-0 space-y-2 text-xs" key={row.id} padding="sm">
                <RepositoryLink row={row} />
                <dl className="grid min-w-0 grid-cols-2 gap-2">
                  <Row label="Owner" value={row.owner || "—"} />
                  <Row label="Name" value={row.name || "—"} />
                  <Row label="Default branch" value={row.defaultBranch || "—"} />
                  <Row label="Epic policy" value={row.epicDependencyPolicy || "—"} />
                  <Row label="Created" value={row.createdAt || "—"} />
                </dl>
              </Surface>
            ))}
          </div>
          <table className="hidden w-full table-fixed text-left text-xs sm:table">
            <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
              <tr>
                {["Repository", "Owner", "Name", "Default branch", "Epic policy", "Created"].map((label) => (
                  <th className="px-2 py-1 font-semibold" key={label} scope="col">
                    {label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
              {result.rows.map((row) => (
                <tr key={row.id}>
                  <td className="break-words px-2 py-1">
                    <RepositoryLink row={row} />
                  </td>
                  {[row.owner, row.name, row.defaultBranch, row.epicDependencyPolicy, row.createdAt].map((value, index) => (
                    <td className="break-words px-2 py-1 text-gray-600 dark:text-gray-300" key={index}>
                      {value || "—"}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
      <PaginationSummary result={result} />
    </div>
  )
}

const listRepositoriesToolCard: ToolCardRenderer = { toolName: "list_repositories", collapsedSummary, renderExpanded }
export default listRepositoriesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "repositories_with_links",
    label: "Repositories with links and pagination",
    input: { page: 1, per_page: 20 },
    parsedResult: {
      repositories: [
        {
          id: 1,
          slug: "tkadauke/syrus",
          owner: "tkadauke",
          name: "syrus",
          default_branch: "main",
          epic_dependency_policy: "linear",
          created_at: "2026-01-08T12:30:00Z",
          html_url: "https://github.com/tkadauke/syrus"
        },
        {
          id: 2,
          slug: "acme/widget-app",
          owner: "acme",
          name: "widget-app",
          default_branch: "trunk",
          epic_dependency_policy: "independent",
          created_at: "2026-02-09T09:15:00Z"
        }
      ],
      pagination: { page: 1, per_page: 20, total_count: 2, total_pages: 1, has_next_page: false }
    }
  },
  {
    id: "no_repositories",
    label: "No repositories",
    description: "Empty result set with complete pagination metadata.",
    parsedResult: { repositories: [], pagination: { page: 1, per_page: 20, total_count: 0, total_pages: 0, has_next_page: false } }
  },
  {
    id: "repository_list_error",
    label: "Error loading repositories",
    input: { page: 2 },
    resultError: true,
    resultBody: "Repository access is temporarily unavailable."
  }
]
