import { withRoutePrefix } from "../lib/routing"
import type { RepositoryTab } from "../api/repositories"
import { useT } from "../hooks/useT"
import { UnderlineTabs } from "./Tabs"

export function RepositoryTabs({ active, prefix, tabs }: { active: string; prefix: string; tabs: RepositoryTab[] }) {
  const { t } = useT("nav")
  return (
    <UnderlineTabs
      activeKey={active}
      activeClassName="border-brand text-brand dark:text-brand-emphasis"
      ariaLabel={t("repository_tabs_aria")}
      className="flex flex-wrap border-b border-gray-200 dark:border-gray-700"
      inactiveClassName="border-transparent text-gray-600 dark:text-gray-400 hover:border-gray-300 dark:hover:border-gray-500 hover:text-gray-900 dark:hover:text-gray-100"
      itemClassName="-mb-px inline-flex items-center gap-1.5 px-4 py-2 text-sm"
      items={tabs.map((tab) => ({
        key: tab.key,
        label: tab.label,
        to: withRoutePrefix(tab.path, prefix),
        badge: tab.badge ? <span className="inline-flex h-4 min-w-4 items-center justify-center rounded-full bg-red-500 px-1 text-2xs leading-none text-white">{tab.badge}</span> : null
      }))}
    />
  )
}
