// Primary view for investigation Jobs (Job#investigation), rendered instead
// of the PR-shaped SummaryTab -- there is no PR, no agent_pr_title/body, and
// no submit_summary/test_plan step in Workflows::Investigation's chain, so
// the submit_report deliverable (narrative + findings + referenced
// artifacts) is the Job's whole output. Reuses ArtifactBody, the same
// typed_artifacts renderer the Artifacts tab uses, for referenced evidence.
import { useT } from "../../hooks/useT"
import { Markdown } from "../../lib/Markdown"
import { SectionHeading } from "../../components/Heading"
import { Section } from "../../components/ui"
import { ArtifactBody } from "../../components/artifacts/TypedArtifactPanel"
import type { JobDetailPayload } from "../../api/jobs"
import { NeedsAttentionBanner } from "./components"

export function ReportTab({ payload }: { payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const report = payload.report

  return (
    <div className="space-y-4">
      <NeedsAttentionBanner job={payload.job} />

      <Section.Root className="min-w-0 overflow-x-auto">
        <SectionHeading className="break-words">{report?.title || t("report_untitled")}</SectionHeading>
        {report ? (
          <>
            <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={report.narrative} />
            {report.findings.length > 0 ? (
              <>
                <h3 className="mt-4 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">{t("report_findings")}</h3>
                <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-300">
                  {report.findings.map((finding, index) => (
                    <li key={index}>{finding}</li>
                  ))}
                </ul>
              </>
            ) : null}
          </>
        ) : (
          <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("report_not_submitted")}</p>
        )}
      </Section.Root>

      {report?.references.map((reference, index) => (
        reference.artifact ? (
          <div className="min-w-0 overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900" key={`${reference.type}-${index}`}>
            <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1 border-b border-gray-100 px-4 py-2 dark:border-gray-800">
              <span className="min-w-0 break-words font-semibold text-gray-800 dark:text-gray-100">{reference.caption || reference.artifact.title}</span>
              <span className="min-w-0 break-all text-xs text-gray-400 dark:text-gray-500">{reference.type}</span>
            </div>
            <div className="overflow-x-auto p-4">
              <ArtifactBody artifact={reference.artifact} />
            </div>
          </div>
        ) : null
      ))}
    </div>
  )
}
