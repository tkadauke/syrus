import { withRoutePrefix } from "../lib/routing"
import { Link } from "react-router-dom"
import type { RepositoryTab } from "../api/repositories"
import { useT } from "../hooks/useT"

export function RepositoryTabs({ active, prefix, tabs }: { active: string; prefix: string; tabs: RepositoryTab[] }) {
  const { t } = useT("nav")
  return (
    <nav className="flex flex-wrap border-b border-gray-200 dark:border-gray-700" aria-label={t("repository_tabs_aria")}>
      {tabs.map((tab) => (
        <Link
          className={`-mb-px inline-flex items-center gap-1.5 border-b-2 px-4 py-2 text-sm font-medium ${tab.key === active ? "border-blue-600 text-blue-600 dark:text-blue-400" : "border-transparent text-gray-600 dark:text-gray-400 hover:border-gray-300 dark:hover:border-gray-500 hover:text-gray-900 dark:hover:text-gray-100"}`}
          key={tab.key}
          to={withRoutePrefix(tab.path, prefix)}
        >
          {tab.label}
          {tab.badge ? <span className="inline-flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-[10px] leading-none text-white">{tab.badge}</span> : null}
        </Link>
      ))}
    </nav>
  )
}

