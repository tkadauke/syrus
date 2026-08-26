import { useT } from "../hooks/useT"
import { formatBytes } from "../lib/format"
import { RelativeTimestamp } from "./RelativeTimestamp"
import type { JobSccacheInfo } from "../api/jobs"
import { Card } from "./Card"
import { TonePill, type PillTone } from "./StatusPill"

type SccacheCardProps = {
  sccache: JobSccacheInfo
}

export function SccacheCard({ sccache }: SccacheCardProps) {
  const { t } = useT("jobs")
  const { summary } = sccache
  const hasCounts = summary.hits != null && summary.misses != null
  const cacheSize = formatCacheSize(summary.cache_size)
  const maxCacheSize = formatCacheSize(summary.max_cache_size)

  return (
    <Card data-testid="sccache-card">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("sccache_title")}</h2>

      {hasCounts ? (
        <div className="mt-3 flex flex-wrap gap-3" data-testid="sccache-summary">
          <SccacheBadge label={t("sccache_hits")} value={String(summary.hits)} tone="green" />
          <SccacheBadge label={t("sccache_misses")} value={String(summary.misses)} tone="gray" />
          <SccacheBadge label={t("sccache_hit_rate")} value={summary.hit_rate != null ? `${summary.hit_rate.toFixed(1)}%` : "—"} tone={hitRateTone(summary.hit_rate)} />
        </div>
      ) : (
        <p className="mt-2 text-sm text-gray-400 dark:text-gray-500">{t("sccache_counts_unavailable")}</p>
      )}

      {cacheSize || maxCacheSize ? (
        <div className="mt-2 text-xs text-gray-500 dark:text-gray-400">
          {cacheSize ? <span>{t("sccache_cache_size")}: {cacheSize}</span> : null}
          {cacheSize && maxCacheSize ? " · " : null}
          {maxCacheSize ? <span>{t("sccache_max_cache_size")}: {maxCacheSize}</span> : null}
        </div>
      ) : null}

      {summary.cache_location ? (
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("sccache_cache_location")}: {summary.cache_location}</div>
      ) : null}

      <div className="mt-3 text-xs text-gray-400 dark:text-gray-500">
        {t("sccache_context", { label: sccache.label ?? "—", stepKind: sccache.step_kind ?? "—", iteration: sccache.iteration ?? "—" })}
        {" · "}
        <RelativeTimestamp value={sccache.captured_at} />
      </div>
    </Card>
  )
}

function formatCacheSize(value: number | string | null): string | null {
  if (value == null) return null
  return typeof value === "number" ? formatBytes(value) : value
}

function SccacheBadge({ label, value, tone }: { label: string; value: string; tone: PillTone }) {
  return (
    <TonePill tone={tone}>
      <span className="flex items-center gap-1.5">
        <span className="text-gray-500 dark:text-gray-400">{label}</span>
        <span>{value}</span>
      </span>
    </TonePill>
  )
}

function hitRateTone(hitRate: number | null): PillTone {
  if (hitRate == null) return "red"
  if (hitRate >= 70) return "green"
  if (hitRate >= 40) return "amber"
  return "red"
}
