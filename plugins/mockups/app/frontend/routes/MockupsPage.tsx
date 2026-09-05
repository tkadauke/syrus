import { useQuery } from "@tanstack/react-query"
import { useLocation, useNavigate, useParams } from "react-router-dom"

import { FilterBar } from "@app/components/FilterBar"
import { PageHeading } from "@app/components/Heading"
import { PanelMessage } from "@app/components/PanelMessage"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { CloseIcon } from "@app/components/CloseIcon"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { withRoutePrefix } from "@app/lib/routing"
import { fetchMockup, fetchMockups, type MockupSummary } from "../api/mockups"
import { MockupPreviewPanel } from "./MockupPreviewPanel"

// The list and the quick preview are one page: selecting a mockup opens it in
// the side panel rather than navigating away, so the filtered list stays put.
export default function MockupsPage() {
  const { t } = useT("mockups")
  const location = useLocation()
  const navigate = useNavigate()
  const params = useParams()
  const selectedRef = params.id ?? null

  usePageTitle(t("title"))

  const listQuery = useQuery({
    queryKey: ["mockups", location.search],
    queryFn: () => fetchMockups(location.search)
  })

  const detailQuery = useQuery({
    queryKey: ["mockup", selectedRef],
    queryFn: () => fetchMockup(selectedRef!),
    enabled: !!selectedRef
  })

  const select = (mockup: MockupSummary) =>
    navigate({ pathname: withRoutePrefix(`/mockups/${mockup.slug}`, ""), search: location.search })

  const closePreview = () =>
    navigate({ pathname: withRoutePrefix("/mockups", ""), search: location.search })

  return (
    <main aria-label={t("title")} className="flex h-full min-h-0 flex-col gap-3 p-4">
      <PageHeading>{t("title")}</PageHeading>

      <FilterBar
        filter={listQuery.data?.filter}
        filterSchema={listQuery.data?.filter_schema ?? []}
        pathname="/mockups"
        search={location.search}
      />

      <div className="flex min-h-0 flex-1 gap-3">
        <div className="min-h-0 flex-1 overflow-auto rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
          {listQuery.isPending ? (
            <PanelMessage>{t("loading")}</PanelMessage>
          ) : listQuery.isError ? (
            <PanelMessage>{t("load_failed")}</PanelMessage>
          ) : listQuery.data.mockups.length === 0 ? (
            <PanelMessage>{t("empty")}</PanelMessage>
          ) : (
            <ul>
              {listQuery.data.mockups.map((mockup) => {
                const selected = mockup.slug === selectedRef || String(mockup.id) === selectedRef
                return (
                  <li key={mockup.id}>
                    <button
                      aria-current={selected ? "true" : undefined}
                      className={`flex w-full items-center gap-3 border-b border-gray-100 px-3 py-2 text-left hover:bg-gray-50 dark:border-gray-800 dark:hover:bg-gray-800 ${selected ? "bg-gray-50 dark:bg-gray-800" : ""}`}
                      onClick={() => select(mockup)}
                      type="button"
                    >
                      <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{mockup.slug}</span>
                      <span className="min-w-0 flex-1 truncate text-sm text-gray-900 dark:text-gray-100">{mockup.title}</span>
                      <span className="text-xs text-gray-400">{t("file_count", { count: mockup.file_count })}</span>
                      {mockup.updated_at ? (
                        <RelativeTimestamp className="text-xs text-gray-400" value={mockup.updated_at} />
                      ) : null}
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>

        {selectedRef ? (
          <aside
            aria-label={t("preview_aria")}
            className="flex min-h-0 w-1/2 flex-col rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900"
          >
            <div className="flex items-center gap-2 border-b border-gray-200 px-3 py-2 dark:border-gray-700">
              <span className="min-w-0 flex-1 truncate text-sm font-medium text-gray-900 dark:text-gray-100">
                {detailQuery.data?.mockup.title ?? selectedRef}
              </span>
              <button
                aria-label={t("close_preview")}
                className="rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-700 dark:hover:bg-gray-800"
                onClick={closePreview}
                type="button"
              >
                <CloseIcon className="h-3.5 w-3.5" />
              </button>
            </div>
            {detailQuery.isPending ? (
              <PanelMessage>{t("loading")}</PanelMessage>
            ) : detailQuery.isError ? (
              <PanelMessage>{t("preview_unavailable")}</PanelMessage>
            ) : (
              <MockupPreviewPanel panel={detailQuery.data.panel} />
            )}
          </aside>
        ) : null}
      </div>
    </main>
  )
}
