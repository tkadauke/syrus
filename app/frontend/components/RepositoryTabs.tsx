import { Link } from "react-router-dom"

type RepositoryTabKey = "overview" | "github_issues" | "context" | "documents" | "scheduled_tasks"

export function RepositoryTabs({ active, prefix, repositoryId }: { active: RepositoryTabKey; prefix: string; repositoryId: number }) {
  const tabs = [
    { key: "overview", label: "Overview", to: `${prefix}/repositories/${repositoryId}` },
    { key: "github_issues", label: "GitHub Issues", to: `${prefix}/repositories/${repositoryId}?tab=github_issues` },
    { key: "context", label: "Context", to: `${prefix}/repositories/${repositoryId}?tab=context` },
    { key: "documents", label: "Documents", to: `${prefix}/repositories/${repositoryId}/documents` },
    { key: "scheduled_tasks", label: "Scheduled Tasks", to: `${prefix}/repositories/${repositoryId}/scheduled_tasks` }
  ] satisfies Array<{ key: RepositoryTabKey; label: string; to: string }>

  return (
    <nav className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" aria-label="Repository tabs">
      {tabs.map((tab) => (
        <Link className={navClass(active === tab.key)} key={tab.key} to={tab.to}>{tab.label}</Link>
      ))}
    </nav>
  )
}

function navClass(active: boolean) {
  return `border-b-2 px-4 py-2 text-sm font-medium ${active ? "border-blue-600 text-blue-600 dark:text-blue-400" : "border-transparent text-gray-600 dark:text-gray-400 hover:border-gray-300 dark:hover:border-gray-500 hover:text-gray-900 dark:hover:text-gray-100"}`
}
