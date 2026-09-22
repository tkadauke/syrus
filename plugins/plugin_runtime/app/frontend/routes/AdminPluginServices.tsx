import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Button, DataTable, Notice, Page, PageHeading, Pill, Section, SectionHeading, Text, Toolbar } from "@app/components/ui"
import type { SemanticTone } from "@app/components/ui"
import { useConfirm } from "@app/hooks/useConfirm"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import {
  fetchPluginServiceLogs,
  fetchPluginServices,
  runPluginServiceAction,
  type PluginService
} from "../api/pluginServices"

const QUERY_KEY = ["admin", "plugin_services"]
const LOG_TAILS = [100, 200, 500, 1000, 2000]

const STATE_TONES: Record<string, SemanticTone> = {
  running: "success",
  starting: "info",
  pulling: "info",
  pending: "info",
  stopped: "warning",
  unhealthy: "warning",
  absent: "neutral",
  error: "danger",
  unavailable: "danger",
  unconfigured: "danger"
}

export function AdminPluginServices() {
  const { t } = useT("plugin_runtime")
  usePageTitle(t("heading"))
  const [logsFor, setLogsFor] = useState<string | null>(null)
  const services = useQuery({
    queryKey: QUERY_KEY,
    queryFn: fetchPluginServices,
    refetchInterval: 10_000
  })
  const payload = services.data

  return (
    <Page.Root aria-label={t("heading")} size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Text className="font-medium uppercase" variant="caption" tone="muted">{t("admin:section_label")}</Text>
        <PageHeading>{t("heading")}</PageHeading>
        <Page.Description className="max-w-3xl">{t("description")}</Page.Description>
      </Page.Header>

      {services.isPending ? <Text tone="muted">{t("loading")}</Text> : null}
      {services.isError ? <Notice tone="danger">{t("load_error")}</Notice> : null}

      {payload ? (
        <>
          {!payload.manageable ? <Notice tone="info">{t("external_notice")}</Notice> : null}
          {payload.manager_error ? <Notice tone="warning">{t("manager_unreachable", { error: payload.manager_error })}</Notice> : null}

          <Section.Root>
            {payload.services.length === 0 ? (
              <Text tone="muted">{t("empty")}</Text>
            ) : (
              <ServicesTable services={payload.services} onShowLogs={setLogsFor} logsFor={logsFor} />
            )}
          </Section.Root>

          {logsFor ? <LogsPanel name={logsFor} onClose={() => setLogsFor(null)} /> : null}
        </>
      ) : null}
    </Page.Root>
  )
}

function ServicesTable({ services, onShowLogs, logsFor }: { services: PluginService[]; onShowLogs: (name: string) => void; logsFor: string | null }) {
  const { t } = useT("plugin_runtime")

  return (
    <DataTable.Root>
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_service")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_plugin")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_state")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_image")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_endpoint")}</DataTable.HeadCell>
          <DataTable.HeadCell align="right">{t("col_actions")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {services.map((service) => (
          <DataTable.Row key={service.service}>
            <DataTable.Cell className="font-mono text-xs">{service.service}</DataTable.Cell>
            <DataTable.Cell>{service.plugin ?? "-"}</DataTable.Cell>
            <DataTable.Cell>
              <div className="flex flex-wrap items-center gap-1.5">
                <Pill tone={STATE_TONES[service.state] ?? "neutral"}>{t(`state.${service.state}`, { defaultValue: service.state })}</Pill>
                {service.held ? <Pill tone="warning">{t("held")}</Pill> : null}
                {!service.desired ? <Pill tone="neutral">{t("orphaned")}</Pill> : null}
              </div>
              {service.error ? <Text className="mt-1 break-words" variant="caption" tone="danger">{service.error}</Text> : null}
            </DataTable.Cell>
            <DataTable.Cell className="break-all font-mono text-xs">{service.image ?? "-"}</DataTable.Cell>
            <DataTable.Cell className="font-mono text-xs">{service.endpoint ?? "-"}</DataTable.Cell>
            <DataTable.Cell align="right">
              <ServiceActions service={service} onShowLogs={onShowLogs} logsOpen={logsFor === service.service} />
            </DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function ServiceActions({ service, onShowLogs, logsOpen }: { service: PluginService; onShowLogs: (name: string) => void; logsOpen: boolean }) {
  const { t } = useT("plugin_runtime")
  const queryClient = useQueryClient()
  const { confirm, dialog } = useConfirm()
  const action = useMutation({
    mutationFn: (name: "stop" | "start" | "restart") => runPluginServiceAction(service.service, name),
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: QUERY_KEY })
      void queryClient.invalidateQueries({ queryKey: ["admin", "plugin_services_logs", service.service] })
    }
  })

  async function run(name: "stop" | "start" | "restart") {
    if (name !== "start") {
      const confirmed = await confirm({
        message: t(name === "stop" ? "confirm_stop" : "confirm_restart", { service: service.service, plugin: service.plugin ?? "" }),
        destructive: name === "stop"
      })
      if (!confirmed) return
    }
    action.mutate(name)
  }

  return (
    <div className="flex flex-col items-end gap-1">
      {dialog}
      <Toolbar className="justify-end">
        {service.actions.includes("start") ? (
          <Button disabled={action.isPending} onClick={() => void run("start")} size="sm" variant="primary">{t("start")}</Button>
        ) : null}
        {service.actions.includes("restart") ? (
          <Button disabled={action.isPending} onClick={() => void run("restart")} size="sm" variant="secondary">{t("restart")}</Button>
        ) : null}
        {service.actions.includes("stop") ? (
          <Button disabled={action.isPending} onClick={() => void run("stop")} size="sm" variant="danger">{t("stop")}</Button>
        ) : null}
        {service.actions.includes("logs") ? (
          <Button aria-pressed={logsOpen} onClick={() => onShowLogs(service.service)} size="sm" variant="secondary">{t("logs")}</Button>
        ) : null}
      </Toolbar>
      {action.isError ? <Text variant="caption" tone="danger">{action.error instanceof Error ? action.error.message : t("action_failed")}</Text> : null}
    </div>
  )
}

function LogsPanel({ name, onClose }: { name: string; onClose: () => void }) {
  const { t } = useT("plugin_runtime")
  const [tail, setTail] = useState(200)
  const [follow, setFollow] = useState(false)
  const logs = useQuery({
    queryKey: ["admin", "plugin_services_logs", name, tail],
    queryFn: () => fetchPluginServiceLogs(name, tail),
    refetchInterval: follow ? 3_000 : false
  })

  return (
    <Section.Root aria-label={t("logs_heading", { service: name })}>
      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <SectionHeading>{t("logs_heading", { service: name })}</SectionHeading>
        <Toolbar>
          <label className="text-sm text-text-primary" htmlFor="plugin-service-log-tail">{t("lines")}</label>
          <select
            className="rounded border border-border bg-surface px-2 py-1 text-sm text-text-primary"
            id="plugin-service-log-tail"
            onChange={(event) => setTail(Number(event.target.value))}
            value={tail}
          >
            {LOG_TAILS.map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
          <label className="flex items-center gap-1.5 text-sm text-text-primary">
            <input checked={follow} onChange={(event) => setFollow(event.target.checked)} type="checkbox" />
            {t("follow")}
          </label>
          <Button disabled={logs.isFetching} onClick={() => void logs.refetch()} size="sm" variant="secondary">{t("refresh")}</Button>
          <Button onClick={onClose} size="sm" variant="secondary">{t("close_logs")}</Button>
        </Toolbar>
      </div>
      {logs.isError ? <Notice tone="danger">{logs.error instanceof Error ? logs.error.message : t("logs_error")}</Notice> : null}
      <pre
        aria-label={t("logs_output", { service: name })}
        className="max-h-[32rem] overflow-auto whitespace-pre-wrap break-words rounded border border-border bg-surface px-3 py-2 font-mono text-xs text-text-primary"
      >
        {logs.isPending ? t("loading") : logs.data?.logs || t("logs_empty")}
      </pre>
    </Section.Root>
  )
}

export default AdminPluginServices
