import type { ReactNode } from "react"
import { RepositoryTabs } from "./RepositoryTabs"
import type { RepositoryTab } from "../api/repositories"

/*
 * Shared layout for the repository detail tabs: heading -> tip banner ->
 * tab bar -> tab-specific content, inside the standard page container.
 * Extracted from RepositoryDetail.tsx (Overview) so other repository tabs
 * can adopt the same header/tab-bar/container without hand-rolling it.
 */
export function RepositoryPageShell({
  activeTab,
  ariaLabel,
  children,
  heading,
  prefix,
  tabs,
  tipBanner
}: {
  activeTab: string
  ariaLabel?: string
  children: ReactNode
  heading: ReactNode
  prefix: string
  tabs: RepositoryTab[]
  tipBanner?: ReactNode
}) {
  return (
    <main aria-label={ariaLabel} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>{heading}</header>
      {tipBanner}
      <RepositoryTabs active={activeTab} prefix={prefix} tabs={tabs} />
      {children}
    </main>
  )
}
