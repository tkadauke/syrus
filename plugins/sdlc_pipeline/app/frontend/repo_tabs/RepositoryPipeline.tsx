import { useQuery } from "@tanstack/react-query"
import { useLocation, useParams } from "react-router-dom"
import { PageHeading, Notice, Section, SectionHeading, Text } from "@app/components/ui"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { TonePill } from "@app/components/StatusPill"
import { useT } from "@app/hooks/useT"
import { routePrefix } from "@app/lib/routing"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchPipeline, type PipelineStage } from "../api/pipeline"

function PipelineColumn({ stage }: { stage: PipelineStage }) {
  const { t } = useT("sdlc_pipeline")
  return (
    <Section.Root className="min-w-64 p-3">
      <div className="flex items-center justify-between gap-2">
        <SectionHeading as="h3">{stage.label}</SectionHeading>
        <TonePill tone={stage.attention_count > 0 ? "amber" : "gray"}>{stage.total}</TonePill>
      </div>
      <Text className="mt-1" variant="caption" tone="muted">
        {t("stage_summary", { attention: stage.attention_count, aging: stage.aging_count })}
      </Text>
      <div className="mt-3 space-y-2">
        {stage.highlighted_items.map((item) => (
          <a className="block rounded border border-border bg-surface-raised p-2 hover:border-brand" href={`/jobs/${item.slug}`} key={item.id}>
            <div className="flex items-start justify-between gap-2">
              <span className="text-sm font-medium text-primary">{item.title}</span>
              {item.needs_attention ? <TonePill tone="amber">{t("attention")}</TonePill> : null}
            </div>
            <Text className="mt-1" variant="caption" tone="muted">
              {item.slug} · {t(`evidence_${item.evidence.type}`)}
            </Text>
          </a>
        ))}
        {stage.total === 0 ? (
          <Text variant="caption" tone="muted">
            {t("empty_stage")}
          </Text>
        ) : null}
      </div>
    </Section.Root>
  )
}

export function RepositoryPipelineRoute({ repositoryId, prefix }: { repositoryId: string; prefix: string }) {
  const { t } = useT("sdlc_pipeline")
  const pipeline = useQuery({
    queryKey: ["repositories", repositoryId, "sdlc_pipeline"],
    queryFn: () => fetchPipeline(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <RepositoryPageShell
      activeTab="sdlc_pipeline.repository"
      ariaLabel={t("aria_pipeline")}
      heading={pipeline.data ? <PageHeading mono>{pipeline.data.repository.slug}</PageHeading> : null}
      prefix={prefix}
      tabs={pipeline.data?.tabs ?? []}
    >
      {pipeline.isPending ? <Notice>{t("loading")}</Notice> : null}
      {pipeline.isError ? <Notice tone="danger">{errorMessage(pipeline.error, t("load_error"))}</Notice> : null}
      {pipeline.data ? (
        <div className="overflow-x-auto pb-3">
          <div className="grid min-w-max auto-cols-[16rem] grid-flow-col gap-3">
            {pipeline.data.stages.map((stage) => (
              <PipelineColumn key={stage.key} stage={stage} />
            ))}
          </div>
        </div>
      ) : null}
    </RepositoryPageShell>
  )
}

export default function RepositoryPipelineTab() {
  const params = useParams<{ repositoryId: string }>()
  const location = useLocation()
  return <RepositoryPipelineRoute repositoryId={params.repositoryId || ""} prefix={routePrefix(location.pathname)} />
}
