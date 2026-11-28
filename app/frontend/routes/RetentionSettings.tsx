import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ComponentProps, FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { fetchRetentionArchives, type RetentionArchiveRow } from "../api/retentionArchives"
import { createBuildNetworkRule, deleteBuildNetworkRule, fetchRetentionSettings, updateBuildNetworkRule, updateRetentionSettings, type BuildNetworkRule, type BuildNetworkRuleInput, type RetentionSettingsPayload, type RetentionTableRow } from "../api/retentionSettings"
import { disabledPaginationClass, paginationLinkClass } from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading, SectionHeading } from "../components/Heading"
import { Select } from "../components/Select"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { formatNumber } from "../lib/format"

const queryKey = ["admin", "retention_settings"] as const

function hasNumericValue(value: string): boolean {
  return value.trim() !== ""
}

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
  return formatNumber(count)
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
      <StorageLimitsCard payload={payload} />
      <RuntimeEnvironmentPolicyCard onNotice={onNotice} payload={payload} />

      <section className="divide-y divide-border rounded border border-border bg-surface">
        {payload.tables.map((table) => (
          <TableRow availableBytes={payload.available_space?.available_bytes ?? null} key={table.key} onNotice={onNotice} table={table} />
        ))}
      </section>
    </>
  )
}

function RuntimeEnvironmentPolicyCard({ payload, onNotice }: { payload: RetentionSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const environment = payload.runtime_environment
  const [policy, setPolicy] = useState(environment.policy)

  useEffect(() => setPolicy(environment.policy), [environment.policy])

  const save = useMutation({
    mutationFn: () => updateRetentionSettings({ runtime_environment_policy: policy }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("retention_settings.settings_updated"))
    }
  })

  const numberField = (section: "builder" | "base_promotion" | "recovery" | "worker_cache" | "scratch", key: string, min = 0) => (
    <label className="text-xs text-text-secondary">
      {t(`retention_settings.environment.${section}_${key}`)}
      <Input
        className="mt-1 w-full"
        min={min}
        onChange={(event) => setPolicy((current) => ({ ...current, [section]: { ...current[section], [key]: Number(event.target.value) } }))}
        type="number"
        value={String((policy[section] as Record<string, number | boolean>)[key])}
      />
    </label>
  )

  return (
    <section className="rounded border border-border bg-surface p-6 space-y-5">
      <div>
        <SectionHeading>{t("retention_settings.environment.heading")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("retention_settings.environment.description")}</p>
      </div>

      <div className="rounded border border-border p-4">
        <h3 className="text-sm font-medium text-text-primary">{t("retention_settings.environment.oci_heading")}</h3>
        <p className="mt-1 text-xs text-text-secondary">
          {environment.oci_registry.configured
            ? t("retention_settings.environment.oci_configured", { url: environment.oci_registry.url, prefix: environment.oci_registry.repository_prefix })
            : t("retention_settings.environment.oci_unconfigured")}
        </p>
        {environment.oci_registry.error ? <p className="mt-1 text-xs text-danger">{environment.oci_registry.error}</p> : null}
        <p className="mt-1 text-xs text-text-secondary">{t("retention_settings.environment.oci_credentials", { roles: Object.entries(environment.oci_registry.credentials).filter(([, present]) => present).map(([role]) => role).join(", ") || t("retention_settings.environment.none") })}</p>
      </div>

      <PolicyGroup heading={t("retention_settings.environment.builder_heading")}>
        {numberField("builder", "max_concurrent_builds", 1)}
        {numberField("builder", "max_concurrent_per_namespace", 1)}
        {numberField("builder", "max_attempts", 1)}
        {numberField("builder", "cpus", 0.1)}
        {numberField("builder", "memory_bytes", 1)}
        {numberField("builder", "pids", 1)}
        {numberField("builder", "storage_bytes", 1)}
        {numberField("builder", "timeout_seconds", 1)}
        {numberField("builder", "log_bytes", 1)}
        {numberField("builder", "max_output_bytes", 1)}
      </PolicyGroup>

      <PolicyGroup heading={t("retention_settings.environment.supply_chain_heading")}>
        <label className="text-xs text-text-secondary sm:col-span-2">
          {t("retention_settings.environment.blocked_severities")}
          <Input className="mt-1" onChange={(event) => setPolicy((current) => ({ ...current, supply_chain: { ...current.supply_chain, blocked_severities: commaList(event.target.value) } }))} value={policy.supply_chain.blocked_severities.join(", ")} />
        </label>
        <label className="text-xs text-text-secondary sm:col-span-2">
          {t("retention_settings.environment.prohibited_packages")}
          <Input className="mt-1" onChange={(event) => setPolicy((current) => ({ ...current, supply_chain: { ...current.supply_chain, prohibited_packages: commaList(event.target.value) } }))} value={policy.supply_chain.prohibited_packages.join(", ")} />
        </label>
      </PolicyGroup>

      <PolicyGroup heading={t("retention_settings.environment.lifecycle_heading")}>
        {numberField("base_promotion", "minimum_abi", 1)}
        {numberField("base_promotion", "maximum_abi", 1)}
        {numberField("recovery", "launch_failure_threshold", 1)}
        {numberField("recovery", "rollback_retention_count")}
        <Checkbox checked={policy.revocation.terminate_running_turns_on_severe} label={t("retention_settings.environment.terminate_severe")} onChange={(event) => setPolicy((current) => ({ ...current, revocation: { terminate_running_turns_on_severe: event.target.checked } }))} />
      </PolicyGroup>

      <PolicyGroup heading={t("retention_settings.environment.cache_scratch_heading")}>
        {numberField("worker_cache", "max_bytes")}
        {numberField("worker_cache", "max_concurrent_pulls", 1)}
        {numberField("worker_cache", "unused_retention_hours", 1)}
        <Checkbox checked={policy.scratch.enabled} label={t("retention_settings.environment.scratch_enabled")} onChange={(event) => setPolicy((current) => ({ ...current, scratch: { ...current.scratch, enabled: event.target.checked } }))} />
        {numberField("scratch", "size_bytes", 1)}
      </PolicyGroup>

      <BuildNetworkRulesEditor environment={environment} onNotice={onNotice} />

      <Button disabled={save.isPending} onClick={() => save.mutate()} type="button">{save.isPending ? t("retention_settings.saving") : t("retention_settings.environment.save_environment_policy")}</Button>
      {save.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(save.error, t("retention_settings.error_update"))}</p> : null}
    </section>
  )
}

type RuntimeEnvironment = RetentionSettingsPayload["runtime_environment"]

const emptyNetworkRule = (sourceClass: string): BuildNetworkRuleInput => ({
  source_class: sourceClass,
  host: "",
  port: 443,
  path_prefix: "",
  ecosystem: "",
  required: false,
  enabled: true,
  note: ""
})

function BuildNetworkRulesEditor({ environment, onNotice }: { environment: RuntimeEnvironment; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const defaultSourceClass = environment.build_network_source_classes[0]?.key || "exact_domain"
  const [editingId, setEditingId] = useState<number | null>(null)
  const [draft, setDraft] = useState<BuildNetworkRuleInput>(() => emptyNetworkRule(defaultSourceClass))
  const sourceMetadata = environment.build_network_source_classes.find((source) => source.key === draft.source_class)

  const acceptUpdate = (updated: RetentionSettingsPayload) => {
    queryClient.setQueryData(queryKey, updated)
    onNotice(updated.message || t("retention_settings.settings_updated"))
    setEditingId(null)
    setDraft(emptyNetworkRule(defaultSourceClass))
  }
  const saveRule = useMutation({
    mutationFn: () => editingId === null ? createBuildNetworkRule(draft) : updateBuildNetworkRule(editingId, draft),
    onSuccess: acceptUpdate
  })
  const deleteRule = useMutation({
    mutationFn: deleteBuildNetworkRule,
    onSuccess: acceptUpdate
  })

  const edit = (rule: BuildNetworkRule) => {
    setEditingId(rule.id)
    setDraft({
      source_class: rule.source_class,
      host: rule.host,
      port: rule.port,
      path_prefix: rule.path_prefix || "",
      ecosystem: rule.ecosystem || "",
      required: rule.required,
      enabled: rule.enabled,
      note: rule.note || ""
    })
  }

  return (
    <div>
      <h3 className="text-sm font-medium text-text-primary">{t("retention_settings.environment.network_heading")}</h3>
      <p className="mt-1 text-xs text-text-secondary">{t("retention_settings.environment.network_description")}</p>
      {environment.build_network_rules.length ? (
        <ul className="mt-3 space-y-2">
          {environment.build_network_rules.map((rule) => (
            <li className="rounded border border-border p-3 text-xs text-text-secondary" key={rule.id}>
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium text-text-primary">{rule.source_class}: {rule.host}{rule.port ? `:${rule.port}` : ""}{rule.path_prefix || ""}</span>
                <span>{rule.enabled ? t("retention_settings.environment.network_enabled") : t("retention_settings.environment.network_disabled")}</span>
                {rule.ecosystem ? <span>{t("retention_settings.environment.network_ecosystem", { ecosystem: rule.ecosystem })}</span> : null}
                {rule.required ? <span>{t("retention_settings.environment.mirror_required")}</span> : null}
              </div>
              {rule.note ? <p className="mt-1">{rule.note}</p> : null}
              <div className="mt-2 flex gap-2">
                <Button onClick={() => edit(rule)} size="sm" variant="secondary">{t("retention_settings.environment.network_edit")}</Button>
                <Button disabled={deleteRule.isPending} onClick={() => deleteRule.mutate(rule.id)} size="sm" variant="danger">{t("retention_settings.environment.network_delete")}</Button>
              </div>
            </li>
          ))}
        </ul>
      ) : <p className="mt-2 text-xs text-warning">{t("retention_settings.environment.network_empty")}</p>}

      <form className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3" onSubmit={(event: FormEvent) => { event.preventDefault(); saveRule.mutate() }}>
        <label className="text-xs text-text-secondary">
          {t("retention_settings.environment.network_source_class")}
          <Select className="mt-1" onChange={(event) => setDraft((current) => ({ ...current, source_class: event.target.value, path_prefix: "", ecosystem: "", required: false }))} value={draft.source_class}>
            {environment.build_network_source_classes.map((source) => <option key={source.key} value={source.key}>{source.key}</option>)}
          </Select>
        </label>
        <NetworkInput label={t("retention_settings.environment.network_host")} onChange={(host) => setDraft((current) => ({ ...current, host }))} required value={draft.host} />
        <NetworkInput label={t("retention_settings.environment.network_port")} onChange={(port) => setDraft((current) => ({ ...current, port: port ? Number(port) : null }))} type="number" value={draft.port?.toString() || ""} />
        {sourceMetadata?.path_scoped ? <NetworkInput label={t("retention_settings.environment.network_path_prefix")} onChange={(path_prefix) => setDraft((current) => ({ ...current, path_prefix }))} required value={draft.path_prefix || ""} /> : null}
        {sourceMetadata?.ecosystem_required || draft.source_class === "internal_mirror" ? (
          <label className="text-xs text-text-secondary">
            {t("retention_settings.environment.network_ecosystem_label")}
            <Select className="mt-1" onChange={(event) => setDraft((current) => ({ ...current, ecosystem: event.target.value }))} required={sourceMetadata?.ecosystem_required} value={draft.ecosystem || ""}>
              <option value="">{t("retention_settings.environment.network_ecosystem_all")}</option>
              {environment.build_network_ecosystems.map((ecosystem) => <option key={ecosystem} value={ecosystem}>{ecosystem}</option>)}
            </Select>
          </label>
        ) : null}
        <NetworkInput label={t("retention_settings.environment.network_note")} onChange={(note) => setDraft((current) => ({ ...current, note }))} value={draft.note || ""} />
        <div className="flex flex-col justify-end gap-2">
          <Checkbox checked={draft.enabled} label={t("retention_settings.environment.network_enabled_label")} onChange={(event) => setDraft((current) => ({ ...current, enabled: event.target.checked }))} />
          {sourceMetadata?.requirable ? <Checkbox checked={draft.required} label={t("retention_settings.environment.network_required_label")} onChange={(event) => setDraft((current) => ({ ...current, required: event.target.checked }))} /> : null}
        </div>
        <div className="flex items-end gap-2">
          <Button disabled={saveRule.isPending} size="sm" type="submit">{editingId === null ? t("retention_settings.environment.network_add") : t("retention_settings.environment.network_save")}</Button>
          {editingId !== null ? <Button onClick={() => { setEditingId(null); setDraft(emptyNetworkRule(defaultSourceClass)) }} size="sm" variant="secondary">{t("retention_settings.environment.network_cancel")}</Button> : null}
        </div>
      </form>
      {saveRule.isError || deleteRule.isError ? <p className="mt-2 text-xs text-danger" role="alert">{errorMessage(saveRule.error || deleteRule.error, t("retention_settings.environment.network_error"))}</p> : null}
    </div>
  )
}

function NetworkInput({ label, onChange, value, ...props }: { label: string; onChange: (value: string) => void; value: string } & Omit<ComponentProps<typeof Input>, "onChange" | "value">) {
  return <label className="text-xs text-text-secondary">{label}<Input className="mt-1 w-full" onChange={(event) => onChange(event.target.value)} value={value} {...props} /></label>
}

function PolicyGroup({ heading, children }: { heading: string; children: ReactNode }) {
  return <fieldset><legend className="text-sm font-medium text-text-primary">{heading}</legend><div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{children}</div></fieldset>
}

function commaList(value: string): string[] {
  return value.split(",").map((item) => item.trim().toLowerCase()).filter(Boolean)
}

function StorageLimitsCard({ payload }: { payload: RetentionSettingsPayload }) {
  const { t } = useT("admin")
  const limits = payload.storage_limits

  return (
    <section className="rounded border border-border bg-surface p-6 space-y-3">
      <SectionHeading>{t("retention_settings.storage_limits_label")}</SectionHeading>
      <dl className="grid gap-4 sm:grid-cols-2">
        <Stat label={t("retention_settings.prepared_cache_default_label")} value={formatStorageLimit(limits.prepared_layer_cache_default_bytes, t)} />
        <Stat label={t("retention_settings.coding_workspace_limit_label")} value={formatStorageLimit(limits.coding_workspace_bytes, t)} />
      </dl>
      <div>
        <p className="text-sm font-medium text-text-primary">{t("retention_settings.prepared_cache_workers_label")}</p>
        {limits.prepared_layer_cache_workers.length > 0 ? (
          <ul className="mt-2 space-y-1 text-xs text-text-secondary">
            {limits.prepared_layer_cache_workers.map((worker) => (
              <li key={worker.worker_storage_key || worker.hostname}>
                {worker.hostname}: {formatStorageLimit(worker.budget_bytes, t)} ({t(`retention_settings.prepared_cache_source_${worker.source}`)})
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-1 text-xs text-text-secondary">{t("retention_settings.prepared_cache_workers_unknown")}</p>
        )}
      </div>
    </section>
  )
}

function formatStorageLimit(bytes: number, t: (key: string) => string): string {
  return bytes > 0 ? formatBytes(bytes) : t("retention_settings.unlimited")
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
            disabled={save.isPending || !hasNumericValue(overrideGb)}
            onClick={() => {
              onNotice(null)
              save.mutate()
            }}
            type="button"
          >
            {save.isPending ? t("retention_settings.saving") : t("retention_settings.save")}
          </Button>
        </div>
        {save.isError ? (
          <p className="mt-1 text-xs text-danger" role="alert">
            {errorMessage(save.error, t("retention_settings.error_update"))}
          </p>
        ) : null}
      </div>
    </section>
  )
}

function TableRow({
  table,
  availableBytes,
  onNotice
}: {
  table: RetentionTableRow
  availableBytes: number | null
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const isInfinite = table.retention_value === 0
  const [infinite, setInfinite] = useState(isInfinite)
  const [value, setValue] = useState(String(table.retention_value || table.default_value))
  const [archiveBeforeDelete, setArchiveBeforeDelete] = useState(table.archive_before_delete)
  const [showArchives, setShowArchives] = useState(false)
  const [validationError, setValidationError] = useState<string | null>(null)

  useEffect(() => {
    setInfinite(table.retention_value === 0)
    setValue(String(table.retention_value || table.default_value))
    setArchiveBeforeDelete(table.archive_before_delete)
  }, [table.retention_value, table.default_value, table.archive_before_delete])

  const save = useMutation({
    mutationFn: (retentionValue: number) =>
      updateRetentionSettings({
        [table.setting_key]: retentionValue,
        [`${table.setting_key}_infinite`]: infinite,
        ...(table.archive_setting_key ? { [table.archive_setting_key]: archiveBeforeDelete } : {})
      }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("retention_settings.settings_updated"))
    }
  })

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const retentionValue = finiteRetentionValue(value, infinite)
    if (retentionValue == null) {
      setValidationError(t("retention_settings.retention_value_required"))
      return
    }

    setValidationError(null)
    onNotice(null)
    save.mutate(retentionValue)
  }

  const percentOfAvailable =
    availableBytes && table.estimated_max_byte_size != null && availableBytes > 0 ? Math.min(100, (table.estimated_max_byte_size / availableBytes) * 100) : null

  return (
    <div>
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
              min={1}
              onChange={(event) => {
                setValue(event.target.value)
                setValidationError(null)
              }}
              required={!infinite}
              type="number"
              value={infinite ? "" : value}
            />
            <span className="text-xs text-text-secondary">{t(`retention_settings.unit_${table.unit}`)}</span>
          </div>
          <Checkbox
            checked={infinite}
            label={<span className="text-xs text-text-primary">{t("retention_settings.infinite_label")}</span>}
            onChange={(event) => {
              setInfinite(event.target.checked)
              setValidationError(null)
            }}
          />
          {table.archivable ? (
            <Checkbox
              checked={archiveBeforeDelete}
              label={<span className="text-xs text-text-primary">{t("retention_settings.archives.archive_before_delete_label")}</span>}
              onChange={(event) => setArchiveBeforeDelete(event.target.checked)}
            />
          ) : null}
          <Button disabled={save.isPending || (!infinite && !hasNumericValue(value))} size="sm" type="submit">
            {save.isPending ? t("retention_settings.saving") : t("retention_settings.save")}
          </Button>
          {validationError ? (
            <p className="text-xs text-danger" role="alert">
              {validationError}
            </p>
          ) : null}
          {save.isError ? (
            <p className="text-xs text-danger" role="alert">
              {errorMessage(save.error, t("retention_settings.error_update"))}
            </p>
          ) : null}
          {table.archivable ? (
            <button className="text-left text-xs text-brand hover:underline" onClick={() => setShowArchives((shown) => !shown)} type="button">
              {showArchives ? t("retention_settings.archives.hide") : t("retention_settings.archives.show")}
            </button>
          ) : null}
        </div>
      </form>
      {table.archivable && showArchives ? (
        <div className="border-t border-border bg-surface-subtle px-4 py-3">
          <ArchiveHistory tableKey={table.key} />
        </div>
      ) : null}
    </div>
  )
}

function finiteRetentionValue(value: string, infinite: boolean): number | null {
  if (infinite) return 0

  const trimmed = value.trim()
  if (trimmed === "") return null

  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed) || parsed < 1) return null

  return parsed
}

// Left off the shared column-config primitive: rendered once per retention
// table (nested inside that table's own settings row) as a compact text-xs
// prune-history log with every column already essential to reading a single
// prune event -- not a persistent cross-table grid worth a picker/reorder menu.
function ArchiveHistory({ tableKey }: { tableKey: string }) {
  const { t } = useT("admin")
  const [page, setPage] = useState(1)
  const archives = useQuery({
    queryKey: ["admin", "retention_archives", tableKey, page],
    queryFn: () => fetchRetentionArchives(tableKey, page)
  })

  if (archives.isPending) return <p className="text-xs text-text-secondary">{t("retention_settings.archives.loading")}</p>
  if (archives.isError) {
    return (
      <p className="text-xs text-danger" role="alert">
        {errorMessage(archives.error, t("retention_settings.archives.error_load"))}
      </p>
    )
  }

  const { archives: rows, pagination } = archives.data

  if (rows.length === 0) {
    return <p className="text-xs text-text-secondary">{t("retention_settings.archives.empty")}</p>
  }

  return (
    <div className="space-y-2">
      <table className="w-full text-left text-xs">
        <thead>
          <tr className="text-text-secondary">
            <th className="pb-1 pr-3 font-medium">{t("retention_settings.archives.col_pruned_before")}</th>
            <th className="pb-1 pr-3 font-medium">{t("retention_settings.archives.col_row_count")}</th>
            <th className="pb-1 pr-3 font-medium">{t("retention_settings.archives.col_byte_size")}</th>
            <th className="pb-1 pr-3 font-medium">{t("retention_settings.archives.col_created_at")}</th>
            <th className="pb-1 font-medium">{t("retention_settings.archives.col_download")}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <ArchiveRow key={row.id} row={row} />
          ))}
        </tbody>
      </table>

      {pagination.total_pages > 1 ? (
        <div className="flex items-center justify-between text-xs text-text-secondary">
          <span>
            {t("retention_settings.archives.showing", {
              first: pagination.first_item,
              last: pagination.last_item,
              total: pagination.total
            })}
          </span>
          <div className="flex gap-2">
            <button
              className={page > 1 ? paginationLinkClass() : disabledPaginationClass()}
              disabled={page <= 1}
              onClick={() => setPage((current) => current - 1)}
              type="button"
            >
              {t("retention_settings.archives.previous")}
            </button>
            <button
              className={page < pagination.total_pages ? paginationLinkClass() : disabledPaginationClass()}
              disabled={page >= pagination.total_pages}
              onClick={() => setPage((current) => current + 1)}
              type="button"
            >
              {t("retention_settings.archives.next")}
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

function ArchiveRow({ row }: { row: RetentionArchiveRow }) {
  const { t } = useT("admin")

  return (
    <tr className="border-t border-border">
      <td className="py-1 pr-3 text-text-primary">{new Date(row.pruned_before).toLocaleString()}</td>
      <td className="py-1 pr-3 text-text-primary">{formatRowCount(row.row_count)}</td>
      <td className="py-1 pr-3 text-text-primary">{formatBytes(row.byte_size)}</td>
      <td className="py-1 pr-3 text-text-primary">{new Date(row.created_at).toLocaleString()}</td>
      <td className="py-1">
        {row.download_path ? (
          <a className="text-brand hover:underline" href={row.download_path}>
            {t("retention_settings.archives.download")}
          </a>
        ) : (
          <span className="text-text-secondary">{t("retention_settings.archives.no_file")}</span>
        )}
      </td>
    </tr>
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
    return (
      <Stat
        label={t("retention_settings.space_used_label")}
        value={<span className="text-text-secondary">{t("retention_settings.available_space_unknown")}</span>}
      />
    )
  }

  if (percent == null) {
    return (
      <Stat
        label={t("retention_settings.space_used_label")}
        value={<span className="text-text-secondary">{t("retention_settings.space_used_not_applicable")}</span>}
      />
    )
  }

  return (
    <Stat
      label={t("retention_settings.space_used_label")}
      value={
        <div className="flex items-center gap-2">
          <div
            aria-label={t("retention_settings.space_used_label")}
            aria-valuemax={100}
            aria-valuemin={0}
            aria-valuenow={Math.round(percent)}
            className="h-2 w-20 overflow-hidden rounded-full bg-surface-subtle"
            role="progressbar"
          >
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
