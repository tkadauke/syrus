import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import {
  fetchRetentionSettings,
  updateRetentionSettings,
  type RetentionSettingsPayload,
  type RetentionTableRow
} from "../api/retentionSettings"
import { Button } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading, SectionHeading } from "../components/Heading"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["admin", "retention_settings"] as const

// Local TB/GB-capable variant, matching AdminOverview's own duplicate --
// the shared lib/format.ts formatBytes caps out at MB, which reads oddly
// for whole-instance available-space comparisons.
function formatBytes(bytes: number): string {
  const units: Array<[number, string]> = [
    [1024 ** 4, "TB"],
    [1024 ** 3, "GB"],
    [1024 ** 2, "MB"]
  ]
  const [factor, suffix] = units.find(([unit]) => bytes >= unit) || [1024, "KB"]
  const value = bytes / factor
  return `${value >= 10 ? Math.round(value) : Math.round(value * 10) / 10}${suffix}`
}

function formatRowCount(count: number): string {
  return new Intl.NumberFormat("en-US").format(count)
}

export function RetentionSettings() {
  const { t } = useT("admin")
  const [notice, setNotice] = useState<string | null>(null)
  const settings = useQuery({
    queryKey,
    queryFn: fetchRetentionSettings
  })

  return (
    <main aria-label={t("aria_retention_settings")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-border pb-4">
        <p className="text-xs font-medium uppercase text-text-secondary">{t("section_label")}</p>
        <PageHeading className="mt-1">{t("retention_settings.heading")}</PageHeading>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {settings.isPending ? <PanelMessage>{t("retention_settings.loading")}</PanelMessage> : null}
      {settings.isError ? <PanelMessage tone="error">{errorMessage(settings.error, t("retention_settings.error_load"))}</PanelMessage> : null}
      {settings.isSuccess ? <RetentionSettingsView onNotice={setNotice} payload={settings.data} /> : null}
    </main>
  )
}

function RetentionSettingsView({ payload, onNotice }: { payload: RetentionSettingsPayload; onNotice: (message: string | null) => void }) {
  return (
    <>
      <AvailableSpaceCard onNotice={onNotice} payload={payload} />

      <section className="divide-y divide-border rounded border border-border bg-surface">
        {payload.tables.map((table) => (
          <TableRow
            availableBytes={payload.available_space?.available_bytes ?? null}
            key={table.key}
            onNotice={onNotice}
            table={table}
          />
        ))}
      </section>
    </>
  )
}

function AvailableSpaceCard({ payload, onNotice }: { payload: RetentionSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [overrideGb, setOverrideGb] = useState(String(payload.retention_available_space_override_gb))

  useEffect(() => {
    setOverrideGb(String(payload.retention_available_space_override_gb))
  }, [payload.retention_available_space_override_gb])

  const save = useMutation({
    mutationFn: () => updateRetentionSettings({ retention_available_space_override_gb: Number(overrideGb) }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("retention_settings.settings_updated"))
    }
  })

  const space = payload.available_space

  return (
    <section className="rounded border border-border bg-surface p-6 space-y-3">
      <SectionHeading>{t("retention_settings.available_space_label")}</SectionHeading>

      {space?.available_bytes != null ? (
        <p className="text-sm text-text-primary">
          {formatBytes(space.available_bytes)}
          <span className="ml-2 text-xs text-text-secondary">
            {space.source === "manual" ? t("retention_settings.available_space_manual") : t("retention_settings.available_space_measured")}
          </span>
        </p>
      ) : (
        <p className="text-sm text-text-secondary">{t("retention_settings.available_space_unknown")}</p>
      )}

      <div>
        <label className="block text-sm font-medium text-text-primary" htmlFor="retention-available-space-override">
          {t("retention_settings.available_space_override_label")}
        </label>
        <span className="mt-1 block text-xs text-text-secondary">{t("retention_settings.available_space_override_help")}</span>
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <Input
            className="w-32"
            fullWidth={false}
            id="retention-available-space-override"
            min={0}
            onChange={(event) => setOverrideGb(event.target.value)}
            placeholder={t("retention_settings.available_space_override_placeholder")}
            type="number"
            value={overrideGb}
          />
          <Button
            disabled={save.isPending}
            onClick={() => { onNotice(null); save.mutate() }}
            type="button"
          >
            {save.isPending ? t("retention_settings.saving") : t("retention_settings.save")}
          </Button>
        </div>
        {save.isError ? <p className="mt-1 text-xs text-danger" role="alert">{errorMessage(save.error, t("retention_settings.error_update"))}</p> : null}
      </div>
    </section>
  )
}

function TableRow({ table, availableBytes, onNotice }: { table: RetentionTableRow; availableBytes: number | null; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const isInfinite = table.retention_value === 0
  const [infinite, setInfinite] = useState(isInfinite)
  const [value, setValue] = useState(String(table.retention_value || table.default_value))

  useEffect(() => {
    setInfinite(table.retention_value === 0)
    setValue(String(table.retention_value || table.default_value))
  }, [table.retention_value, table.default_value])

  const save = useMutation({
    mutationFn: () => updateRetentionSettings({ [table.setting_key]: infinite ? 0 : Number(value) }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("retention_settings.settings_updated"))
    }
  })

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    save.mutate()
  }

  const percentOfAvailable = availableBytes && table.estimated_max_byte_size != null && availableBytes > 0
    ? Math.min(100, (table.estimated_max_byte_size / availableBytes) * 100)
    : null

  return (
    <form className="flex flex-col gap-4 p-4 sm:flex-row sm:items-start sm:justify-between" onSubmit={submit}>
      <div className="sm:w-56 sm:shrink-0">
        <div className="text-sm font-medium text-text-primary">{table.table_name}</div>
        <div className="mt-1 text-xs text-text-secondary">{table.description}</div>
      </div>

      <div className="grid flex-1 grid-cols-1 gap-4 sm:grid-cols-3">
        <Stat label={t("retention_settings.current_size_label")} value={currentSizeText(t, table)} />
        <Stat label={t("retention_settings.estimated_max_label")} value={estimatedMaxText(t, table)} />
        <SpaceStat availableBytes={availableBytes} percent={percentOfAvailable} t={t} />
      </div>

      <div className="flex flex-col gap-2 sm:w-56 sm:shrink-0">
        <div className="flex items-center gap-2">
          <Input
            aria-label={t("retention_settings.retention_value_label", { table: table.table_name })}
            className="w-24"
            disabled={infinite}
            fullWidth={false}
            id={`retention-value-${table.key}`}
            min={0}
            onChange={(event) => setValue(event.target.value)}
            type="number"
            value={infinite ? "" : value}
          />
          <span className="text-xs text-text-secondary">{t(`retention_settings.unit_${table.unit}`)}</span>
        </div>
        <Checkbox
          checked={infinite}
          label={<span className="text-xs text-text-primary">{t("retention_settings.infinite_label")}</span>}
          onChange={(event) => setInfinite(event.target.checked)}
        />
        <Button disabled={save.isPending} size="sm" type="submit">
          {save.isPending ? t("retention_settings.saving") : t("retention_settings.save")}
        </Button>
        {save.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(save.error, t("retention_settings.error_update"))}</p> : null}
      </div>
    </form>
  )
}

function Stat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div>
      <div className="text-xs uppercase tracking-wide text-text-secondary">{label}</div>
      <div className="mt-1 text-sm text-text-primary">{value}</div>
    </div>
  )
}

function SpaceStat({ availableBytes, percent, t }: { availableBytes: number | null; percent: number | null; t: ReturnType<typeof useT<"admin">>["t"] }) {
  if (availableBytes == null) {
    return <Stat label={t("retention_settings.space_used_label")} value={<span className="text-text-secondary">{t("retention_settings.available_space_unknown")}</span>} />
  }

  if (percent == null) {
    return <Stat label={t("retention_settings.space_used_label")} value={<span className="text-text-secondary">{t("retention_settings.space_used_not_applicable")}</span>} />
  }

  return (
    <Stat
      label={t("retention_settings.space_used_label")}
      value={
        <div className="flex items-center gap-2">
          <div aria-label={t("retention_settings.space_used_label")} aria-valuemax={100} aria-valuemin={0} aria-valuenow={Math.round(percent)} className="h-2 w-20 overflow-hidden rounded-full bg-surface-subtle" role="progressbar">
            <div className="h-full rounded-full bg-brand" style={{ width: `${percent}%` }} />
          </div>
          <span>{percent < 1 ? "<1" : Math.round(percent)}%</span>
        </div>
      }
    />
  )
}

function currentSizeText(t: ReturnType<typeof useT<"admin">>["t"], table: RetentionTableRow): ReactNode {
  if (table.row_count_estimate == null || table.byte_size_estimate == null) {
    return <span className="text-text-secondary">{t("retention_settings.current_size_unknown")}</span>
  }

  return t("retention_settings.current_size_value", {
    rows: formatRowCount(table.row_count_estimate),
    bytes: formatBytes(table.byte_size_estimate)
  })
}

function estimatedMaxText(t: ReturnType<typeof useT<"admin">>["t"], table: RetentionTableRow): ReactNode {
  if (table.retention_value === 0) return t("retention_settings.estimated_max_unbounded")
  if (table.estimated_max_byte_size == null) return <span className="text-text-secondary">{t("retention_settings.current_size_unknown")}</span>

  return formatBytes(table.estimated_max_byte_size)
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-danger" : "text-text-secondary"}`}>{children}</div>
}
