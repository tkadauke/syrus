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
  if (!data.current.length) return "No live workers"
  const unhealthy = data.current.filter((w) => parseHealthLevel(obj(w.health)?.level) !== "ok").length
  return unhealthy
    ? `${unhealthy} of ${data.current.length} worker${data.current.length === 1 ? "" : "s"} need attention`
    : `${data.current.length} worker${data.current.length === 1 ? "" : "s"} healthy`
}

function Host({ value }: { value: unknown }) {
  const hostname = displayValue(value) ?? "—"
  const { copied, copy } = useCopyToClipboard()
  return (
    <span className="inline-flex min-w-0 items-center gap-1">
      <span className="break-all font-mono font-semibold">{hostname}</span>
      {hostname !== "—" ? (
        <button
          aria-label={`Copy ${hostname} to clipboard`}
          className="inline-flex h-5 w-5 shrink-0 items-center justify-center rounded text-text-subtle hover:bg-surface-raised"
          onClick={() => copy(hostname)}
          title={copied ? "Copied" : `Copy ${hostname}`}
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
  if (!count) return <span className="text-text-subtle">no samples</span>
  const critical = num(w?.critical_count) ?? 0,
    warning = num(w?.warning_count) ?? 0
  return (
    <span>
      {count} samples{critical ? `, ${critical} critical` : warning ? `, ${warning} warning` : ""}
    </span>
  )
}

function Sample({ sample }: { sample: Obj | null }) {
  if (!sample) return <EmptyState>No recent host health sample.</EmptyState>
  return (
    <Table responsive>
      <THead columns={["Observed", "Load 1/5/15m", "CPU", "Memory", "Disk", "CPU pressure", "IO pressure"]} />
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
    <Disclosure label={`Worker details · ${host}`}>
      <div className="space-y-2">
        <div className="grid gap-2 sm:grid-cols-3">
          <Row label="ID" value={displayValue(worker.id) ?? "—"} />
          <Row label="Storage key" value={displayValue(worker.worker_storage_key) ?? "—"} />
          <Row label="Version" value={displayValue(worker.version) ?? "—"} />
          <Row label="Started" value={displayValue(worker.started_at) ?? "—"} />
          <Row label="Last heartbeat" value={displayValue(worker.last_heartbeat_at) ?? "—"} />
          <Row label="Seconds since heartbeat" value={displayValue(worker.seconds_since_heartbeat) ?? "—"} />
        </div>
        {Array.isArray(health?.reasons) && health.reasons.length ? (
          <div>
            <SectionLabel>Health reasons</SectionLabel>
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
            ["Desired version", worker.desired_version],
            ["macOS updater", { state: worker.macos_updater_state, status: worker.macos_updater_status }],
            ["macOS worker drain", worker.macos_worker_drain],
            ["Capability diagnostics", worker.capability_diagnostics],
            ["Sample capabilities", sample?.capabilities],
            ["Sample diagnostics", sample?.capability_diagnostics],
            ["Worker trend", worker.trend],
            ["Raw metrics", sample?.raw_metrics]
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
          ["Hostname input", displayValue(input.hostname) ?? "all"],
          ["Since input", displayValue(input.since) ?? "default"],
          ["Until input", displayValue(input.until) ?? "default"],
          ["Sample limit per host", displayValue(input.sample_limit_per_host) ?? "default"],
          ["Minute bucket window input", displayValue(input.minute_bucket_window_minutes) ?? "default"],
          ["Generated at", displayValue(r.generated_at) ?? "—"],
          ["Effective range", `${displayValue(data.range?.since) ?? "—"} → ${displayValue(data.range?.until) ?? "—"}`],
          ["Current sample window", num(r.current_sample_window_seconds) == null ? "—" : `${num(r.current_sample_window_seconds)}s`],
          [
            "Minute bucket",
            bucket
              ? `${displayValue(bucket.granularity_seconds) ?? "—"}s · ${displayValue(bucket.window_minutes) ?? "—"}/${displayValue(bucket.max_window_minutes) ?? "—"}m`
              : "—"
          ]
        ].map(([label, value]) => (
          <Row key={label} label={label} value={value} />
        ))}
      </div>
      {!data.current.length ? (
        <EmptyState>No live workers found.</EmptyState>
      ) : (
        <>
          <Table responsive>
            <THead columns={["Host", "Role", "Health", "Version", "Capabilities", "Heartbeat"]} />
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
                          {w.stale === true ? <span className="text-2xs text-text-muted">(stale)</span> : null}
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
        <Disclosure label="Host trend history">
          <div className="space-y-2">
            <Table responsive>
              <THead columns={["Host", "Status", ...WINDOWS.map((w) => `Last ${w}`)]} />
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
                  <Row label="Storage key" value={displayValue(h.worker_storage_key) ?? "—"} />
                  <SectionLabel>Minute buckets</SectionLabel>
                  <Json value={h.minute_buckets} />
                  <SectionLabel>Recent samples</SectionLabel>
                  <Json value={h.recent_samples} />
                  <SectionLabel>Current snapshot</SectionLabel>
                  <Json value={h.current} />
                  <SectionLabel>Complete window summaries</SectionLabel>
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
