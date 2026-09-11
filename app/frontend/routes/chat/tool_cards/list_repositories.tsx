import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EmptyState } from "../toolCardUi"

// Core-owned tool card for list_repositories (the tool-card work).
type RepositoryRow = { id: string; slug: string; defaultBranch: string | null; epicDependencyPolicy: string | null }

type ListRepositoriesResult = {
  rows: RepositoryRow[]
  page: number | null
  totalPages: number | null
  totalCount: number | null
}

function parseRow(value: unknown): RepositoryRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const slug = displayValue(value.slug)
  if (!id || !slug) return null

  return {
    id,
    slug,
    defaultBranch: displayValue(value.default_branch),
    epicDependencyPolicy: displayValue(value.epic_dependency_policy)
  }
}

function parseResult(context: ToolCardContext): ListRepositoriesResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.repositories)) return null

  const rows = parsed.repositories.flatMap((item) => {
    const row = parseRow(item)
    return row ? [row] : []
  })

  const pagination = isPlainObject(parsed.pagination) ? parsed.pagination : {}
  const page = typeof pagination.page === "number" ? pagination.page : null
  const totalPages = typeof pagination.total_pages === "number" ? pagination.total_pages : null
  const totalCount = typeof pagination.total_count === "number" ? pagination.total_count : null

  return { rows, page, totalPages, totalCount }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const count = result.totalCount ?? result.rows.length
  return count === 0 ? "No repositories" : `${count} repositor${count === 1 ? "y" : "ies"}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.rows.length === 0) return <EmptyState>No repositories found.</EmptyState>

  return (
    <div className="mt-1 space-y-1">
      <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
        <table className="w-full text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              <th className="px-2 py-1 font-semibold" scope="col">
                Repository
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                Default branch
              </th>
              <th className="px-2 py-1 font-semibold" scope="col">
                Epic dependency policy
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {result.rows.map((row) => (
              <tr key={row.id}>
                <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-800 dark:text-gray-200">{row.slug}</td>
                <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.defaultBranch || "—"}</td>
                <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.epicDependencyPolicy || "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {result.page != null && result.totalPages != null ? (
        <div className="text-2xs text-gray-500 dark:text-gray-400">
          Page {result.page} of {result.totalPages}
        </div>
      ) : null}
    </div>
  )
}

const listRepositoriesToolCard: ToolCardRenderer = {
  toolName: "list_repositories",
  collapsedSummary,
  renderExpanded
}

export default listRepositoriesToolCard
