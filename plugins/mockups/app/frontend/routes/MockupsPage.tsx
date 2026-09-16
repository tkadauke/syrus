import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"

import { FilterBar } from "@app/components/FilterBar"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { CloseIcon } from "@app/components/CloseIcon"
import { Notice, Page, PageHeading, Section, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { withRoutePrefix } from "@app/lib/routing"
import { fetchMockup, fetchMockups, type MockupDetailPayload, type MockupPanel, type MockupSummary } from "../api/mockups"
import { MockupPreviewPanel } from "./MockupPreviewPanel"

// The list and the quick preview are one page: selecting a mockup opens it in
// the side panel rather than navigating away, so the filtered list stays put.
export default function MockupsPage() {
  const { t } = useT("mockups")
  const location = useLocation()
  const navigate = useNavigate()
  const params = useParams()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const selectedRef = params.id ?? null
  const detailQueryKey = ["mockup", selectedRef] as const

  usePageTitle(t("title"))

  const listQuery = useQuery({
    queryKey: ["mockups", location.search],
    queryFn: () => fetchMockups(location.search)
  })

  const detailQuery = useQuery({
    queryKey: detailQueryKey,
    queryFn: () => fetchMockup(selectedRef!),
    enabled: !!selectedRef
  })

  const select = (mockup: MockupSummary) =>
    navigate({ pathname: withRoutePrefix(`/mockups/${mockup.slug}`, ""), search: location.search })

  const closePreview = () =>
    navigate({ pathname: withRoutePrefix("/mockups", ""), search: location.search })

  return (
    <Page.Root aria-label={t("title")} className="flex h-full min-h-0 flex-col gap-3 p-4" size="full">
      <PageHeading>{t("title")}</PageHeading>

      <FilterBar
        filter={listQuery.data?.filter}
        filterSchema={listQuery.data?.filter_schema ?? []}
        pathname="/mockups"
        search={location.search}
      />

      <div className="flex min-h-0 flex-1 flex-col gap-3 lg:flex-row">
        <Section.Root className="min-h-[14rem] flex-1 overflow-auto p-0 lg:min-h-0">
          {listQuery.isPending ? (
            <Notice className="m-3">{t("loading")}</Notice>
          ) : listQuery.isError ? (
            <Notice className="m-3" tone="danger">{t("load_failed")}</Notice>
          ) : listQuery.data.mockups.length === 0 ? (
            <Notice className="m-3">{t("empty")}</Notice>
          ) : (
            <ul>
              {listQuery.data.mockups.map((mockup) => {
                const selected = mockup.slug === selectedRef || String(mockup.id) === selectedRef
                return (
                  <li key={mockup.id}>
                    <button
                      aria-current={selected ? "true" : undefined}
                      className={`flex w-full flex-wrap items-center gap-x-3 gap-y-1 border-b border-border px-3 py-2 text-left hover:bg-surface-raised sm:flex-nowrap ${selected ? "bg-surface-raised" : ""}`}
                      onClick={() => select(mockup)}
                      type="button"
                    >
                      <Text as="span" className="font-mono" variant="caption" tone="muted">{mockup.slug}</Text>
                      <Text as="span" className="min-w-0 flex-1 truncate font-medium" tone="default">{mockup.title}</Text>
                      <Text as="span" className="shrink-0" variant="caption" tone="muted">{t("file_count", { count: mockup.file_count })}</Text>
                      {mockup.updated_at ? (
                        <RelativeTimestamp className="shrink-0 text-xs text-text-muted" value={mockup.updated_at} />
                      ) : null}
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </Section.Root>

        {selectedRef ? (
          <aside
            aria-label={t("preview_aria")}
            className="flex min-h-[28rem] flex-col rounded border border-border bg-surface lg:min-h-0 lg:w-1/2"
          >
            <div className="flex items-center gap-2 border-b border-border px-3 py-2">
              <Text as="span" className="min-w-0 flex-1 truncate font-medium" tone="default">
                {detailQuery.data?.mockup.title ?? selectedRef}
              </Text>
              {detailQuery.data?.mockup.chat_path ? (
                <Link
                  className="shrink-0 rounded px-2 py-1 text-xs font-medium text-brand hover:bg-brand/10 dark:text-brand-emphasis"
                  to={withRoutePrefix(detailQuery.data.mockup.chat_path, "")}
                >
                  {t("open_chat")}
                </Link>
              ) : null}
              <button
                aria-label={t("close_preview")}
                className="rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-700 dark:hover:bg-gray-800"
                onClick={closePreview}
                type="button"
              >
                <CloseIcon className="h-3.5 w-3.5" />
              </button>
            </div>
            {notice ? (
              <p className="border-b border-gray-200 px-3 py-2 text-xs text-gray-600 dark:border-gray-700 dark:text-gray-300" role="status">
                {notice}
              </p>
            ) : null}
            {detailQuery.isPending ? (
              <Notice className="m-3">{t("loading")}</Notice>
            ) : detailQuery.isError ? (
              <Notice className="m-3" tone="danger">{t("preview_unavailable")}</Notice>
            ) : (
              <MockupPreviewPanel
                onNotice={setNotice}
                onPanelUpdated={(panel: MockupPanel) => {
                  queryClient.setQueryData<MockupDetailPayload>(detailQueryKey, (current) => current ? { ...current, panel } : current)
                }}
                panel={detailQuery.data.panel}
                queryKey={detailQueryKey}
              />
            )}
          </aside>
        ) : null}
      </div>
    </Page.Root>
  )
}
