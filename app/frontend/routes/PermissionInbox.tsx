import { useQuery } from "@tanstack/react-query"
import { useMemo } from "react"
import { useLocation } from "react-router-dom"
import { fetchPermissionRequests } from "../api/permissionRequests"
import { FilterBar, filterTreeFromPayload, topFilterChildren, type FilterChip, type FilterSchemaField } from "../components/FilterBar"
import { PageHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { PermissionRequestCard } from "../components/PermissionRequestCard"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"

const fields: FilterSchemaField[] = [
  { field: "state", label: "State", bucket: "general", operators: ["eq"], values: ["pending", "confirmed", "rejected", "dismissed", "non_actionable"] },
  { field: "subject", label: "Subject", bucket: "general", operators: ["contains"] },
  { field: "capability", label: "Capability", bucket: "general", operators: ["contains"] },
  { field: "effect", label: "Effect", bucket: "general", operators: ["contains"] }
]

export function PermissionInboxRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  usePageTitle(t("approval_inbox.title"))
  const query = useQuery({ queryKey: ["permission_requests"], queryFn: fetchPermissionRequests })
  const filterTree = decodeFilterTree(location.search)
  const filters = topFilterChildren(filterTree).filter((node): node is FilterChip => "field" in node)
  const requests = useMemo(() => (query.data?.requests ?? []).filter((request) => filters.every((filter) => {
    const value = String(filter.value || "").toLowerCase()
    if (filter.field === "state") return request.state === value
    if (filter.field === "subject") return (request.subject?.label || request.runtime_role || "").toLowerCase().includes(value)
    if (filter.field === "capability") return request.items.some((item) => item.capability.toLowerCase().includes(value))
    if (filter.field === "effect") return request.items.some((item) => item.effects.some((effect) => effect.toLowerCase().includes(value)))
    return true
  })), [filters, query.data])
  return <main className="mx-auto max-w-5xl space-y-5 p-6">
    <header><PageHeading>{t("approval_inbox.title")}</PageHeading><p className="mt-1 text-sm text-text-secondary">{t("approval_inbox.description")}</p></header>
    <FilterBar filter={filterTree} filterSchema={fields} pathname="/permissions/inbox" search={location.search} />
    {query.isError ? <PanelMessage tone="error">{t("approval_inbox.load_error")}</PanelMessage> : null}
    <div className="space-y-4">{requests.map((request) => <PermissionRequestCard key={request.id} request={request} />)}</div>
    {!query.isLoading && !requests.length ? <PanelMessage>{t("approval_inbox.empty")}</PanelMessage> : null}
  </main>
}

function decodeFilterTree(search: string) {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return filterTreeFromPayload(null)
  try {
    const padded = `${encoded.replace(/-/g, "+").replace(/_/g, "/")}${"=".repeat((4 - encoded.length % 4) % 4)}`
    return filterTreeFromPayload(JSON.parse(decodeURIComponent(escape(atob(padded)))))
  } catch { return filterTreeFromPayload(null) }
}
