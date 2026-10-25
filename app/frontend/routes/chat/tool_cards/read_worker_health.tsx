import i18n from "../../../i18n"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CapabilityBadges, CardShell, Disclosure, displayValue, EmptyState, Row, SectionLabel } from "../toolCardUi"
import { formatBytesLarge, formatPercent, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"
import { CopyIcon } from "../../../components/CopyableSlug"
import { useCopyToClipboard } from "../../../hooks/useCopyToClipboard"

type Obj = Record<string, unknown>
const WINDOWS = ["15m", "1h", "6h", "24h"]
const obj = (v: unknown): Obj | null => (isPlainObject(v) ? v : null)
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null)
const json = (v: unknown) => (v == null || (isPlainObject(v) && !Object.keys(v).length) ? "—" : JSON.stringify(v, null, 2))

function parse(context: ToolCardContext) {
  const root = obj(context.parsedResult)
  if (!root || !Array.isArray(root.current)) return null
  return {
    root,
    range: obj(root.range),
    current: root.current.flatMap((v) => (obj(v) ? [obj(v)!] : [])),
    hosts: Array.isArray(root.hosts) ? root.hosts.flatMap((v) => (obj(v) ? [obj(v)!] : [])) : []
  }
}

function summary(context: ToolCardContext) {
  const data = parse(context)
  if (!data) return null
  if (!data.current.length) return i18n.t("chat:ops_no_live_workers_479c0a")
  const unhealthy = data.current.filter((w) => parseHealthLevel(obj(w.health)?.level) !== "ok").length
  return unhealthy
    ? i18n.t("chat:workers_need_attention", { count: data.current.length, unhealthy })
    : i18n.t("chat:healthy_worker_count", { count: data.current.length })
}

function Host({ value }: { value: unknown }) {
  const hostname = displayValue(value) ?? "—"
  const { copied, copy } = useCopyToClipboard()
  return (
    <span className="inline-flex min-w-0 items-center gap-1">
      <span className="break-all font-mono font-semibold">{hostname}</span>
      {hostname !== "—" ? (
        <button
          aria-label={i18n.t("chat:copy_named_to_clipboard", { name: hostname })}
          className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-text-subtle hover:bg-surface-raised"
          onClick={() => copy(hostname)}
          title={copied ? i18n.t("chat:ops_copied_8e3df4") : `Copy ${hostname}`}
          type="button"
        >
          <CopyIcon className="h-3.5 w-3.5" />
        </button>
      ) : null}
    </span>
  )
}

function Json({ value }: { value: unknown }) {
  return <pre className="max-h-56 overflow-auto whitespace-pre-wrap break-all rounded bg-surface-inset p-2 font-mono text-2xs">{json(value)}</pre>
}

function Window({ value }: { value: unknown }) {
  const w = obj(value),
    count = num(w?.sample_count)
  if (count == null) return <>—</>
  if (!count) return <span className="text-text-subtle">{i18n.t("chat:ops_no_samples_e960a1")}</span>
  const critical = num(w?.critical_count) ?? 0,
    warning = num(w?.warning_count) ?? 0
  return (
    <span>
      {count} samples{critical ? `, ${critical} critical` : warning ? `, ${warning} warning` : ""}
    </span>
  )
}

function Sample({ sample }: { sample: Obj | null }) {
  if (!sample) return <EmptyState>{i18n.t("chat:ops_no_recent_host_health_sample_6d263f")}</EmptyState>
  return (
    <Table responsive>
      <THead
        columns={[
          i18n.t("chat:ops_observed_2e159b"),
          "Load 1/5/15m",
          "CPU",
          i18n.t("chat:ops_memory_89c8a2"),
          i18n.t("chat:ops_disk_ef9952"),
          i18n.t("chat:ops_cpu_pressure_dede08"),
          i18n.t("chat:ops_io_pressure_dab860")
        ]}
      />
      <TBody>
        <tr>
          <Td mono wrap>
            {displayValue(sample.observed_at) ?? "—"}
          </Td>
          <Td mono>{[sample.load_1m, sample.load_5m, sample.load_15m].map((v) => num(v) ?? "—").join(" / ")}</Td>
          <Td mono>{formatPercent(num(sample.cpu_used_percent))}</Td>
          <Td mono wrap>
            {formatPercent(num(sample.memory_used_percent))} · {formatBytesLarge(num(sample.memory_available_bytes))} /{" "}
            {formatBytesLarge(num(sample.memory_total_bytes))} free
          </Td>
          <Td mono wrap>
            {formatPercent(num(sample.data_root_used_percent))} · {formatBytesLarge(num(sample.data_root_available_bytes))} /{" "}
            {formatBytesLarge(num(sample.data_root_total_bytes))} free
          </Td>
          <Td mono>
            {formatPercent(num(sample.cpu_pressure_some))} / {formatPercent(num(sample.cpu_pressure_full))}
          </Td>
          <Td mono>
            {formatPercent(num(sample.io_pressure_some))} / {formatPercent(num(sample.io_pressure_full))}
          </Td>
        </tr>
      </TBody>
    </Table>
  )
}

function WorkerDetails({ worker }: { worker: Obj }) {
  const host = displayValue(worker.hostname) ?? "unknown",
    sample = obj(worker.sample),
    health = obj(worker.health)
  return (
    <Disclosure label={i18n.t("chat:worker_details_named", { name: host })}>
      <div className="space-y-2">
        <div className="grid gap-2 sm:grid-cols-3">
          <Row label="ID" value={displayValue(worker.id) ?? "—"} />
          <Row label={i18n.t("chat:ops_storage_key_5641d2")} value={displayValue(worker.worker_storage_key) ?? "—"} />
          <Row label={i18n.t("chat:ops_version_2da600")} value={displayValue(worker.version) ?? "—"} />
          <Row label={i18n.t("chat:ops_started_faa9e7")} value={displayValue(worker.started_at) ?? "—"} />
          <Row label={i18n.t("chat:ops_last_heartbeat_aac4b5")} value={displayValue(worker.last_heartbeat_at) ?? "—"} />
          <Row label={i18n.t("chat:ops_seconds_since_heartbeat_6805dd")} value={displayValue(worker.seconds_since_heartbeat) ?? "—"} />
        </div>
        {Array.isArray(health?.reasons) && health.reasons.length ? (
          <div>
            <SectionLabel>{i18n.t("chat:ops_health_reasons_c1fb5d")}</SectionLabel>
            <ul className="list-disc pl-5 text-xs">
              {health.reasons.map((r, i) => (
                <li className="break-words" key={i}>
                  {displayValue(r) ?? json(r)}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        <Sample sample={sample} />
        <div className="grid gap-2 sm:grid-cols-2">
          {[
            [i18n.t("chat:ops_desired_version_db792c"), worker.desired_version],
            ["macOS updater", { state: worker.macos_updater_state, status: worker.macos_updater_status }],
            ["macOS worker drain", worker.macos_worker_drain],
            [i18n.t("chat:ops_capability_diagnostics_ee3f5a"), worker.capability_diagnostics],
            [i18n.t("chat:ops_sample_capabilities_bbd92e"), sample?.capabilities],
            [i18n.t("chat:ops_sample_diagnostics_2867eb"), sample?.capability_diagnostics],
            [i18n.t("chat:ops_worker_trend_131182"), worker.trend],
            [i18n.t("chat:ops_raw_metrics_a83db5"), sample?.raw_metrics]
          ].map(([label, value]) => (
            <div key={String(label)}>
              <SectionLabel>{String(label)}</SectionLabel>
              <Json value={value} />
            </div>
          ))}
        </div>
      </div>
    </Disclosure>
  )
}

function renderExpanded(context: ToolCardContext) {
  const data = parse(context)
  if (!data) return null
  const r = data.root,
    input = context.input ?? {},
    bucket = obj(r.minute_bucket)
  return (
    <CardShell>
      <div className="grid gap-2 sm:grid-cols-3">
        {[
          [i18n.t("chat:ops_hostname_input_6f1e26"), displayValue(input.hostname) ?? "all"],
          [i18n.t("chat:ops_since_input_e74232"), displayValue(input.since) ?? "default"],
          [i18n.t("chat:ops_until_input_ff8c81"), displayValue(input.until) ?? "default"],
          [i18n.t("chat:ops_sample_limit_per_host_7f981e"), displayValue(input.sample_limit_per_host) ?? "default"],
          [i18n.t("chat:ops_minute_bucket_window_input_d54a21"), displayValue(input.minute_bucket_window_minutes) ?? "default"],
          [i18n.t("chat:ops_generated_at_a2c46b"), displayValue(r.generated_at) ?? "—"],
          [i18n.t("chat:ops_effective_range_701615"), `${displayValue(data.range?.since) ?? "—"} → ${displayValue(data.range?.until) ?? "—"}`],
          [i18n.t("chat:ops_current_sample_window_875d3d"), num(r.current_sample_window_seconds) == null ? "—" : `${num(r.current_sample_window_seconds)}s`],
          [
            i18n.t("chat:ops_minute_bucket_98bbf1"),
            bucket
              ? `${displayValue(bucket.granularity_seconds) ?? "—"}s · ${displayValue(bucket.window_minutes) ?? "—"}/${displayValue(bucket.max_window_minutes) ?? "—"}m`
              : "—"
          ]
        ].map(([label, value]) => (
          <Row key={label} label={label} value={value} />
        ))}
      </div>
      {!data.current.length ? (
        <EmptyState>{i18n.t("chat:ops_no_live_workers_found_3745d9")}</EmptyState>
      ) : (
        <>
          <Table responsive>
            <THead
              columns={[
                i18n.t("chat:ops_host_3960ec"),
                i18n.t("chat:ops_role_c3f104"),
                i18n.t("chat:ops_health_3703cd"),
                i18n.t("chat:ops_version_2da600"),
                i18n.t("chat:ops_capabilities_ca09c5"),
                i18n.t("chat:ops_heartbeat_eb4d41")
              ]}
            />
            <TBody>
              {data.current.map((w, i) => {
                const health = obj(w.health),
                  reasons = Array.isArray(health?.reasons) ? health.reasons : []
                return (
                  <tr key={`${displayValue(w.id) ?? displayValue(w.hostname)}-${i}`}>
                    <Td primary wrap>
                      <Host value={w.hostname} />
                    </Td>
                    <Td>{displayValue(w.role) ?? "—"}</Td>
                    <Td wrap>
                      <div className="space-y-1">
                        <span className="inline-flex gap-1">
                          <HealthPill level={parseHealthLevel(health?.level)} />
                          {w.stale === true ? <span className="text-2xs text-text-muted">{i18n.t("chat:ops_stale_5a5319")}</span> : null}
                        </span>
                        {reasons.length ? (
                          <ul className="list-disc pl-4 text-2xs">
                            {reasons.map((x, j) => (
                              <li className="whitespace-normal" key={j}>
                                {displayValue(x) ?? json(x)}
                              </li>
                            ))}
                          </ul>
                        ) : null}
                      </div>
                    </Td>
                    <Td mono wrap>
                      {displayValue(w.version) ?? "—"}
                    </Td>
                    <Td wrap>
                      <CapabilityBadges capabilities={w.capabilities} />
                    </Td>
                    <Td mono wrap>
                      {displayValue(w.last_heartbeat_at) ?? "—"}
                      {num(w.seconds_since_heartbeat) != null ? ` · ${num(w.seconds_since_heartbeat)}s ago` : ""}
                    </Td>
                  </tr>
                )
              })}
            </TBody>
          </Table>
          {data.current.map((w, i) => (
            <WorkerDetails worker={w} key={`${displayValue(w.id)}-${i}`} />
          ))}
        </>
      )}
      {data.hosts.length ? (
        <Disclosure label={i18n.t("chat:ops_host_trend_history_8e64f8")}>
          <div className="space-y-2">
            <Table responsive>
              <THead columns={[i18n.t("chat:ops_host_3960ec"), i18n.t("chat:ops_status_bae7d5"), ...WINDOWS.map((w) => `Last ${w}`)]} />
              <TBody>
                {data.hosts.map((h, i) => {
                  const windows = obj(h.windows)
                  return (
                    <tr key={`${displayValue(h.key) ?? displayValue(h.hostname)}-${i}`}>
                      <Td primary wrap>
                        <Host value={h.hostname} />
                      </Td>
                      <Td>{displayValue(h.status) ?? "—"}</Td>
                      {WINDOWS.map((w) => (
                        <Td wrap key={w}>
                          <Window value={windows?.[w]} />
                        </Td>
                      ))}
                    </tr>
                  )
                })}
              </TBody>
            </Table>
            {data.hosts.map((h, i) => (
              <Disclosure label={`History details · ${displayValue(h.hostname) ?? "unknown"}`} key={i}>
                <div className="space-y-2">
                  <Row label={i18n.t("chat:ops_storage_key_5641d2")} value={displayValue(h.worker_storage_key) ?? "—"} />
                  <SectionLabel>{i18n.t("chat:ops_minute_buckets_6f39ab")}</SectionLabel>
                  <Json value={h.minute_buckets} />
                  <SectionLabel>{i18n.t("chat:ops_recent_samples_75c95e")}</SectionLabel>
                  <Json value={h.recent_samples} />
                  <SectionLabel>{i18n.t("chat:ops_current_snapshot_69b450")}</SectionLabel>
                  <Json value={h.current} />
                  <SectionLabel>{i18n.t("chat:ops_complete_window_summaries_fd7d35")}</SectionLabel>
                  <Json value={h.windows} />
                </div>
              </Disclosure>
            ))}
          </div>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const readWorkerHealthToolCard: ToolCardRenderer = { toolName: "read_worker_health", collapsedSummary: summary, renderExpanded }
export default readWorkerHealthToolCard
