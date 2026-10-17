import { repositoryDetailPageSearch, repositoryDetailQueryKey } from "./repositoryDetail/shared"
import { CognitiveDebtSection } from "./RepositoryDetail"
import { PanelMessage } from "../components/PanelMessage"
import { PageHeading } from "../components/Heading"
import { RepositoryPageShell } from "../components/RepositoryPageShell"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { Link, useLocation, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { fetchRepositoryDetail, type RepositoryDetailPayload } from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"

export function RepositoryCognitiveDebtRoute() {
  const params = useParams()
  const location = useLocation()
  const id = params.repositoryId || params.id || ""
  const search = repositoryDetailPageSearch(location.search)
  const prefix = routePrefix(location.pathname)
  const detail = useQuery({
    queryKey: repositoryDetailQueryKey(id, search),
    queryFn: () => fetchRepositoryDetail(id, search),
    enabled: id.length > 0
  })
  usePageTitle(detail.data?.repository.slug)

  return <RepositoryCognitiveDebt detail={detail} prefix={prefix} />
}

function RepositoryCognitiveDebt({
  detail,
  prefix
}: {
  detail: { data?: RepositoryDetailPayload; isPending: boolean; isError: boolean; error: unknown }
  prefix: string
}) {
  const { t } = useT("settings")
  const payload = detail.data

  return (
    <RepositoryPageShell
      activeTab="cognitive_debt"
      ariaLabel={t("repository.cognitive_debt_aria")}
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
      {payload ? <CognitiveDebtSection payload={payload} prefix={prefix} /> : null}
    </RepositoryPageShell>
  )
}
