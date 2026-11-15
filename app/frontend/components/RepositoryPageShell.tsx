import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useParams } from "react-router-dom"
import { fetchRepoPluginTabs } from "../api/repoPluginTabs"
import { Page, usePageGutterRestoreClassName } from "./ui/Page"
import { RepositoryTabs } from "./RepositoryTabs"

export const REPOSITORY_TABS_STALE_TIME = 60_000

/*
 * Shared layout for the repository detail tabs: heading -> tip banner ->
 * tab bar -> tab-specific content, inside the standard page container.
 * Extracted from RepositoryDetail.tsx (Overview) so other repository tabs
 * can adopt the same header/tab-bar/container without hand-rolling it.
 * Uses the responsive gutter primitive: the header and tab bar keep the
 * page's normal mobile margin, while tab content runs edge to edge.
 */
export function RepositoryPageShell({
  activeTab,
  ariaLabel,
  children,
  heading,
  prefix,
  tipBanner
}: {
  activeTab: string
  ariaLabel?: string
  children: ReactNode
  heading: ReactNode
  prefix: string
  tipBanner?: ReactNode
}) {
  const { repositoryId = "" } = useParams()
  const tabs = useQuery({
    queryKey: ["repositories", repositoryId, "plugin_tabs"],
    queryFn: () => fetchRepoPluginTabs(repositoryId),
    enabled: repositoryId.length > 0,
    staleTime: REPOSITORY_TABS_STALE_TIME
  })

  return (
    <Page.Root aria-label={ariaLabel} gutter="responsive" size="wide">
      <Page.Header>
        <Page.HeadingGroup>{heading}</Page.HeadingGroup>
      </Page.Header>
      {tipBanner ? <TipBanner>{tipBanner}</TipBanner> : null}
      <Page.Nav>
        <RepositoryTabs
          active={activeTab}
          prefix={prefix}
          tabs={(tabs.data?.tabs ?? []).map((tab) => ({ ...tab, badge: tab.badge ?? undefined }))}
        />
      </Page.Nav>
      {children}
    </Page.Root>
  )
}

// A real descendant of Page.Root (unlike a plain variable computed in
// RepositoryPageShell's own render) so the gutter-restore hook reads the
// context Page.Root actually provides, rather than the default it falls
// back to outside any Page.Root.
function TipBanner({ children }: { children: ReactNode }) {
  const marginGutterRestore = usePageGutterRestoreClassName("margin")
  return <div className={marginGutterRestore}>{children}</div>
}
