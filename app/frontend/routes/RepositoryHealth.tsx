import { repositoryDetailQueryKey } from "./repositoryDetail/shared"
import { MainBranchHealthSection } from "./repositoryDetail/MainBranchHealth"
import { PanelMessage } from "../components/PanelMessage"
import { PageHeading } from "../components/Heading"
import { RepositoryPageShell } from "../components/RepositoryPageShell"
import { NoticeToast } from "../components/NoticeToast"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { fetchRepositoryDetail, fetchRepositoryHealthHistory, type RepositoryDetailPayload } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"

// The Health tab: main branch health, moved out of the Overview tab so it
// no longer competes with recent jobs for attention. Reads/writes the same
// repository detail query cache entry as RepositoryDetail (Overview) --
// the backend still computes the whole detail payload in one request, and
// the health mutations (run graders, check CI, repair, resume landing)
// already respond with that full payload.
export function RepositoryHealthRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.repositoryId || params.id || ""
  const prefix = routePrefix(location.pathname)
  const detailQueryKey = repositoryDetailQueryKey(id)
  const detail = useQuery({
    queryKey: detailQueryKey,
    queryFn: () => fetchRepositoryDetail(id),
    enabled: id.length > 0
  })
  const health = useQuery({ queryKey: ["repositories", id, "health_history"], queryFn: () => fetchRepositoryHealthHistory(id), enabled: id.length > 0 })
  const payload = detail.data && health.data ? { ...detail.data, ...health.data } : undefined
  const composedDetail = {
    ...detail,
    data: payload,
    error: detail.error || health.error,
    isError: detail.isError || health.isError,
    isPending: detail.isPending || health.isPending
  }
  usePageTitle(payload?.repository.slug)

  return <RepositoryHealth detail={composedDetail} prefix={prefix} queryKey={detailQueryKey} />
}

function RepositoryHealth({
  detail,
  prefix,
  queryKey
}: {
  detail: { data?: RepositoryDetailPayload; isPending: boolean; isError: boolean; error: unknown }
  prefix: string
  queryKey: ReturnType<typeof repositoryDetailQueryKey>
}) {
  const { t } = useT("settings")
  const payload = detail.data
  const [notice, setNotice] = useState<string | null>(payload?.message || null)

  return (
    <RepositoryPageShell
      activeTab="health"
      ariaLabel={t("repository.aria_repository_health")}
      heading={
        payload ? (
          <PageHeading mono>
            <Link className="hover:underline" to={withRoutePrefix(`/repositories/${payload.repository.id}`, prefix)}>
              {payload.repository.slug}
            </Link>
          </PageHeading>
        ) : null
      }
      prefix={prefix}
      tabs={payload?.tabs ?? []}
    >
      {detail.isPending ? <PanelMessage>{t("repository.loading")}</PanelMessage> : null}
      {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("repository.error_load"))}</PanelMessage> : null}
      {payload ? (
        <>
          <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
          {payload.health_history ? (
            <MainBranchHealthSection history={payload.health_history} onNotice={setNotice} payload={payload} prefix={prefix} queryKey={queryKey} />
          ) : (
            <PanelMessage>{t("repository.health_tab_empty")}</PanelMessage>
          )}
        </>
      ) : null}
    </RepositoryPageShell>
  )
}
