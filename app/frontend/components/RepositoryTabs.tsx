import { Link } from "react-router-dom"
import type { RepositoryTab } from "../api/repositories"

export function RepositoryTabs({ active, prefix, tabs }: { active: string; prefix: string; tabs: RepositoryTab[] }) {
  return (
    <nav className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" aria-label="Repository tabs">
      {tabs.map((tab) => (
        <Link
          className={`-mb-px border-b-2 px-4 py-2 text-sm font-medium ${tab.key === active ? "border-blue-600 text-blue-600 dark:text-blue-400" : "border-transparent text-gray-600 dark:text-gray-400 hover:border-gray-300 dark:hover:border-gray-500 hover:text-gray-900 dark:hover:text-gray-100"}`}
          key={tab.key}
          to={withRoutePrefix(tab.path, prefix)}
        >
          {tab.label}
        </Link>
      ))}
    </nav>
  )
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path
  return `${prefix}${path}`
}
