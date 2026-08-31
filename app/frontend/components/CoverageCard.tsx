import { useState } from "react"
import { useT } from "../hooks/useT"
import type { CoverageArtifact } from "../api/jobs"
import { Card } from "./Card"
import { TonePill, type PillTone } from "./StatusPill"

type CoverageCardProps = {
  coverage: CoverageArtifact
}

export function CoverageCard({ coverage }: CoverageCardProps) {
  const { t } = useT("jobs")
  const [filesExpanded, setFilesExpanded] = useState(false)

  if (coverage.coverage_unavailable) {
    return (
      <Card>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("coverage_title")}</h2>
        <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("coverage_unavailable")}</p>
      </Card>
    )
  }

  const summary = coverage.summary
  const prDelta = coverage.pr_delta
  const thresholdMiss = coverage.threshold_miss
  const thresholdDetails = coverage.threshold_miss_details
  const files = coverage.files || {}
  const hitMapAttached = coverage.hit_map_attached

  const sortedFiles = Object.entries(files).sort((a, b) => {
    const aLines = a[1].lines_pct ?? 100
    const bLines = b[1].lines_pct ?? 100
    return aLines - bLines
  })

  return (
    <Card data-testid="coverage-card">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("coverage_title")}</h2>

      {summary ? (
        <div className="mt-3 flex flex-wrap gap-3" data-testid="coverage-summary">
          <CoverageBadge label={t("coverage_lines")} pct={summary.lines_pct} />
          <CoverageBadge label={t("coverage_branches")} pct={summary.branches_pct} />
          <CoverageBadge label={t("coverage_functions")} pct={summary.functions_pct} />
        </div>
      ) : null}

      {prDelta && prDelta.total > 0 ? (
        <div className="mt-3 text-sm text-gray-700 dark:text-gray-300" data-testid="coverage-pr-delta">
          <span className="font-medium">{t("coverage_pr_delta_label")}</span>{" "}
          {t("coverage_pr_delta_value", {
            covered: prDelta.covered,
            total: prDelta.total,
            pct: prDelta.pct != null ? prDelta.pct.toFixed(1) : "—"
          })}
        </div>
      ) : null}

      <div className="mt-3" data-testid="coverage-threshold-status">
        {thresholdMiss ? (
          <div className="flex items-start gap-2 text-sm text-red-700 dark:text-red-400">
            <span aria-hidden="true">✗</span>
            <span>{t("coverage_threshold_miss")}</span>
          </div>
        ) : summary ? (
          <div className="flex items-center gap-2 text-sm text-emerald-700 dark:text-emerald-400">
            <span aria-hidden="true">✓</span>
            <span>{t("coverage_threshold_ok")}</span>
          </div>
        ) : null}
        {thresholdMiss && thresholdDetails ? (
          <dl className="mt-1 grid grid-cols-2 gap-x-4 gap-y-1 pl-5 text-xs text-red-600 dark:text-red-400">
            {thresholdDetails.lines_pct != null && thresholdDetails.threshold_lines != null ? (
              <>
                <dt>{t("coverage_threshold_lines_actual")}</dt>
                <dd>{thresholdDetails.lines_pct.toFixed(1)}% <span className="text-gray-400">(threshold: {thresholdDetails.threshold_lines}%)</span></dd>
              </>
            ) : null}
            {thresholdDetails.pr_delta_pct != null && thresholdDetails.threshold_pr_lines != null ? (
              <>
                <dt>{t("coverage_threshold_pr_delta_actual")}</dt>
                <dd>{thresholdDetails.pr_delta_pct.toFixed(1)}% <span className="text-gray-400">(threshold: {thresholdDetails.threshold_pr_lines}%)</span></dd>
              </>
            ) : null}
          </dl>
        ) : null}
      </div>

      {hitMapAttached ? (
        <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">{t("coverage_hit_map_available")}</p>
      ) : null}

      {sortedFiles.length > 0 ? (
        <div className="mt-3">
          <button
            className="text-sm text-brand hover:underline dark:text-brand-emphasis"
            onClick={() => setFilesExpanded((v) => !v)}
            type="button"
          >
            {filesExpanded ? t("coverage_files_hide") : t("coverage_files_show", { count: sortedFiles.length })}
          </button>
          {filesExpanded ? (
            <div className="mt-2 overflow-hidden rounded border border-gray-200 dark:border-gray-700" data-testid="coverage-file-table">
              <table className="min-w-full text-xs">
                <thead>
                  <tr className="bg-gray-50 dark:bg-gray-800">
                    <th className="px-3 py-2 text-left font-medium text-gray-600 dark:text-gray-300">{t("coverage_file_col_path")}</th>
                    <th className="px-3 py-2 text-right font-medium text-gray-600 dark:text-gray-300">{t("coverage_file_col_lines")}</th>
                    <th className="px-3 py-2 text-right font-medium text-gray-600 dark:text-gray-300">{t("coverage_file_col_branches")}</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                  {sortedFiles.map(([path, stats]) => (
                    <tr className="hover:bg-gray-50 dark:hover:bg-gray-800/50" key={path}>
                      <td className="max-w-xs truncate px-3 py-1.5 font-mono text-gray-700 dark:text-gray-300" title={path}>{path}</td>
                      <td className="px-3 py-1.5 text-right">
                        <CoveragePct pct={stats.lines_pct} />
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <CoveragePct pct={stats.branches_pct} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : null}
        </div>
      ) : null}
    </Card>
  )
}

function CoverageBadge({ label, pct }: { label: string; pct: number | null | undefined }) {
  return (
    <TonePill tone={pctTone(pct)}>
      <span className="flex items-center gap-1.5">
        <span className="text-gray-500 dark:text-gray-400">{label}</span>
        <span>{pct != null ? `${pct.toFixed(1)}%` : "—"}</span>
      </span>
    </TonePill>
  )
}

function CoveragePct({ pct }: { pct: number | null | undefined }) {
  if (pct == null) return <span className="text-gray-400">—</span>
  const tone = pctTone(pct)
  const cls = tone === "green"
    ? "text-emerald-700 dark:text-emerald-400"
    : tone === "amber"
    ? "text-amber-700 dark:text-amber-400"
    : "text-red-700 dark:text-red-400"
  return <span className={cls}>{pct.toFixed(1)}%</span>
}

function pctTone(pct: number | null | undefined): PillTone {
  if (pct == null) return "red"
  if (pct >= 80) return "green"
  if (pct >= 60) return "amber"
  return "red"
}
