import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { batchDecidePermissionRequests, fetchPermissionRequests, type PermissionRequest } from "../api/permissionRequests"
import { FilterBar, filterTreeFromPayload, topFilterChildren, type FilterChip, type FilterSchemaField } from "../components/FilterBar"
import { PageHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { PermissionRequestCard } from "../components/PermissionRequestCard"
import { Input } from "../components/Input"
import { Select } from "../components/Select"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"

export function PermissionInboxRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const page = Math.max(1, Number(new URLSearchParams(location.search).get("page")) || 1)
  const fields: FilterSchemaField[] = useMemo(
    () => [
      {
        field: "state",
        label: t("approval_inbox.filters.state"),
        bucket: "general",
        operators: ["eq"],
        values: ["pending", "confirmed", "rejected", "dismissed", "non_actionable"]
      },
      { field: "subject", label: t("approval_inbox.filters.subject"), bucket: "general", operators: ["contains"] },
      { field: "capability", label: t("approval_inbox.filters.capability"), bucket: "general", operators: ["contains"] },
      { field: "effect", label: t("approval_inbox.filters.effect"), bucket: "general", operators: ["contains"] }
    ],
    [t]
  )
  usePageTitle(t("approval_inbox.title"))
  const query = useQuery({ queryKey: ["permission_requests", page], queryFn: () => fetchPermissionRequests(page) })
  const filterTree = useMemo(() => decodeFilterTree(location.search), [location.search])
  const filters = useMemo(() => topFilterChildren(filterTree).filter((node): node is FilterChip => "field" in node), [filterTree])
  const requests = useMemo(
    () =>
      (query.data?.requests ?? []).filter((request) =>
        filters.every((filter) => {
          const value = String(filter.value || "").toLowerCase()
          if (filter.field === "state") return request.state === value
          if (filter.field === "subject") return (request.subject?.label || request.runtime_role || "").toLowerCase().includes(value)
          if (filter.field === "capability") return request.items.some((item) => item.capability.toLowerCase().includes(value))
          if (filter.field === "effect") return request.items.some((item) => item.effects.some((effect) => effect.toLowerCase().includes(value)))
          return true
        })
      ),
    [filters, query.data]
  )
  const pending = requests.filter((request) => request.state === "pending")
  const completed = requests.filter((request) => request.state !== "pending")
  return (
    <main className="mx-auto max-w-5xl space-y-5 p-6">
      <header>
        <PageHeading>{t("approval_inbox.title")}</PageHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("approval_inbox.description")}</p>
      </header>
      <FilterBar filter={filterTree} filterSchema={fields} pathname="/permissions/inbox" search={location.search} />
      {query.isError ? <PanelMessage tone="error">{t("approval_inbox.load_error")}</PanelMessage> : null}
      <RequestSection requests={pending} title={t("approval_inbox.pending_title")} />
      <RequestSection requests={completed} title={t("approval_inbox.history_title")} />
      {!query.isLoading && !requests.length ? <PanelMessage>{t("approval_inbox.empty")}</PanelMessage> : null}
      {query.data && query.data.pagination.total_pages > 1 ? (
        <nav aria-label={t("approval_inbox.pagination")} className="flex items-center justify-between text-sm">
          {page > 1 ? (
            <Link className="font-medium text-brand" to={pagePath(location.search, page - 1)}>
              {t("approval_inbox.previous")}
            </Link>
          ) : (
            <span />
          )}
          <span>{t("approval_inbox.page_of", { page, total: query.data.pagination.total_pages })}</span>
          {page < query.data.pagination.total_pages ? (
            <Link className="font-medium text-brand" to={pagePath(location.search, page + 1)}>
              {t("approval_inbox.next")}
            </Link>
          ) : (
            <span />
          )}
        </nav>
      ) : null}
    </main>
  )
}

function RequestSection({ requests, title }: { requests: PermissionRequest[]; title: string }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [selected, setSelected] = useState<number[]>([])
  const selectedRequests = requests.filter((request) => selected.includes(request.id))
  const durations = compatibleDurations(selectedRequests)
  const [duration, setDuration] = useState("invocation")
  const batchDuration = durations.includes(duration) ? duration : durations[0]
  const batch = useMutation({
    mutationFn: (decision: "approved" | "denied") => batchDecidePermissionRequests(selected, decision, decision === "approved" ? batchDuration : undefined),
    onSuccess: () => {
      setSelected([])
      void queryClient.invalidateQueries({ queryKey: ["permission_requests"] })
    }
  })
  if (!requests.length) return null
  return (
    <section className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-lg font-semibold">{title}</h2>
        {selected.length ? (
          <div className="flex items-center gap-2">
            {durations.length ? (
              <Select aria-label={t("approval_inbox.duration")} fullWidth={false} onChange={(event) => setDuration(event.target.value)} value={batchDuration}>
                {durations.map((choice) => (
                  <option key={choice} value={choice}>
                    {t(`approval_inbox.durations.${choice}`, { defaultValue: choice })}
                  </option>
                ))}
              </Select>
            ) : null}
            <button
              className="rounded bg-brand px-3 py-1.5 text-sm font-semibold text-on-brand"
              disabled={!durations.length || batch.isPending}
              onClick={() => batch.mutate("approved")}
            >
              {t("approval_inbox.approve_selected")}
            </button>
            <button
              className="rounded border border-danger px-3 py-1.5 text-sm font-semibold text-danger"
              disabled={batch.isPending}
              onClick={() => batch.mutate("denied")}
            >
              {t("approval_inbox.deny_selected")}
            </button>
          </div>
        ) : null}
      </div>
      <div className="space-y-4">
        {requests.map((request) => (
          <div className="flex items-start gap-3" key={request.id}>
            {request.state === "pending" && request.actionable ? (
              <Input
                aria-label={t("approval_inbox.select_request", { purpose: request.purpose || request.id })}
                checked={selected.includes(request.id)}
                className="mt-5"
                fullWidth={false}
                onChange={() => setSelected((current) => (current.includes(request.id) ? current.filter((id) => id !== request.id) : [...current, request.id]))}
                type="checkbox"
              />
            ) : null}
            <div className="min-w-0 flex-1">
              <PermissionRequestCard request={request} />
            </div>
          </div>
        ))}
      </div>
    </section>
  )
}

function decodeFilterTree(search: string) {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return filterTreeFromPayload(null)
  try {
    const padded = `${encoded.replace(/-/g, "+").replace(/_/g, "/")}${"=".repeat((4 - (encoded.length % 4)) % 4)}`
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0))
    return filterTreeFromPayload(JSON.parse(new TextDecoder().decode(bytes)))
  } catch {
    return filterTreeFromPayload(null)
  }
}

function compatibleDurations(requests: PermissionRequest[]) {
  const items = requests.flatMap((request) => request.items)
  return items.reduce<string[]>(
    (choices, item, index) => (index === 0 ? item.requested_durations : choices.filter((choice) => item.requested_durations.includes(choice))),
    []
  )
}

function pagePath(search: string, page: number) {
  const params = new URLSearchParams(search)
  params.set("page", String(page))
  return `/permissions/inbox?${params}`
}
