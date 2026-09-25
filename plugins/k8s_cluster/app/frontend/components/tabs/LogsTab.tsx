import { useQuery } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { Button } from "@app/components/Button"
import { Checkbox } from "@app/components/Checkbox"
import { Input } from "@app/components/Input"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPodLogs, fetchKubernetesPods } from "../../api/kubernetesResources"
import { Dropdown } from "../Dropdown"

// Log tail sizes offered in the toolbar. The server defaults to 200 when
// tail_lines is absent, so the default selection mirrors that default.
const TAIL_LINE_OPTIONS = [100, 200, 500, 1000] as const
const DEFAULT_TAIL_LINES = 200
const FOLLOW_REFETCH_INTERVAL_MS = 10_000

// Shared log-output styling, extracted so the empty and populated states
// render identically without duplicating the class list.
const LOG_OUTPUT_CLASSES =
  "max-h-[32rem] overflow-auto rounded border border-gray-200 dark:border-gray-800 bg-gray-950 p-3 text-xs text-gray-100"

export function LogsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const [selectedPodKey, setSelectedPodKey] = useState<string | null>(null)
  const [selectedContainer, setSelectedContainer] = useState<string | null>(null)
  const [tailLines, setTailLines] = useState<number>(DEFAULT_TAIL_LINES)
  const [previous, setPrevious] = useState(false)
  const [timestamps, setTimestamps] = useState(false)
  const [follow, setFollow] = useState(false)
  const [logQuery, setLogQuery] = useState("")

  const pods = useQuery({
    queryKey: [ "k8s_cluster", "pods", clusterId, namespace ],
    queryFn: () => fetchKubernetesPods(clusterId, namespace)
  })

  const selectedPod = pods.data?.pods.find((pod) => `${pod.namespace}/${pod.name}` === selectedPodKey) ?? null

  useEffect(() => {
    if (!selectedPod) {
      setSelectedContainer(null)
      return
    }
    if (!selectedPod.container_names.includes(selectedContainer || "")) {
      setSelectedContainer(selectedPod.container_names[0] ?? null)
    }
    // Only re-derive the container when the selected pod identity changes.
  }, [selectedPod?.namespace, selectedPod?.name])

  const logs = useQuery({
    queryKey: [ "k8s_cluster", "pod_logs", clusterId, selectedPod?.namespace, selectedPod?.name, selectedContainer, tailLines, previous, timestamps ],
    queryFn: () =>
      fetchKubernetesPodLogs(clusterId, selectedPod!.namespace, selectedPod!.name, {
        container: selectedContainer,
        tail_lines: tailLines,
        previous,
        timestamps
      }),
    enabled: !!selectedPod,
    // Follow polls the same read-only tail the manual Refresh button fetches
    // once; turning it off returns to manual-only refreshes.
    refetchInterval: follow ? FOLLOW_REFETCH_INTERVAL_MS : false
  })

  if (pods.isPending) return <PanelMessage>{t("logs_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("logs_error_loading_pods"))}</PanelMessage>

  if (pods.data.pods.length === 0) {
    return <PanelMessage>{t("logs_no_pods")}</PanelMessage>
  }

  const podOptions = pods.data.pods.map((pod) => ({ value: `${pod.namespace}/${pod.name}`, label: `${pod.namespace}/${pod.name}` }))
  const containerOptions = (selectedPod?.container_names ?? []).map((name) => ({ value: name, label: name }))
  const tailLineOptions = TAIL_LINE_OPTIONS.map((lines) => ({ value: String(lines), label: String(lines) }))

  const logLines = splitLogLines(logs.data?.log ?? "")
  const needle = logQuery.trim().toLowerCase()
  const visibleLines = needle ? logLines.filter((line) => line.toLowerCase().includes(needle)) : logLines

  return (
    <div aria-label={t("aria_logs_tab")} className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Dropdown
          ariaLabel={t("logs_pod_label")}
          onChange={setSelectedPodKey}
          options={podOptions}
          placeholder={t("logs_select_pod_placeholder")}
          value={selectedPodKey ?? ""}
        />
        {selectedPod && selectedPod.container_names.length > 1 ? (
          <Dropdown
            ariaLabel={t("logs_container_label")}
            onChange={setSelectedContainer}
            options={containerOptions}
            value={selectedContainer ?? ""}
          />
        ) : null}
        {selectedPod ? (
          <Dropdown
            ariaLabel={t("logs_tail_lines_label")}
            onChange={(value) => setTailLines(Number(value))}
            options={tailLineOptions}
            value={String(tailLines)}
          />
        ) : null}
        {selectedPod ? (
          <Button onClick={() => void logs.refetch()} size="sm" variant="secondary">
            {t("logs_refresh")}
          </Button>
        ) : null}
      </div>

      {selectedPod ? (
        <div className="flex flex-wrap items-center gap-4">
          <Checkbox
            checked={previous}
            label={t("logs_previous_label")}
            onChange={(event) => setPrevious(event.target.checked)}
          />
          <Checkbox
            checked={timestamps}
            label={t("logs_timestamps_label")}
            onChange={(event) => setTimestamps(event.target.checked)}
          />
          <Checkbox
            checked={follow}
            label={t("logs_follow_label")}
            onChange={(event) => setFollow(event.target.checked)}
          />
        </div>
      ) : null}

      {!selectedPod ? <PanelMessage>{t("logs_select_pod")}</PanelMessage> : null}
      {selectedPod && logs.isPending ? <PanelMessage>{t("logs_loading")}</PanelMessage> : null}
      {selectedPod && logs.isError ? <PanelMessage tone="error">{errorMessage(logs.error, t("logs_error_loading"))}</PanelMessage> : null}
      {selectedPod && logs.isSuccess ? (
        <div className="space-y-3">
          <Input
            aria-label={t("logs_search_label")}
            fullWidth={false}
            onChange={(event) => setLogQuery(event.target.value)}
            placeholder={t("logs_search_placeholder")}
            type="search"
            value={logQuery}
          />
          {logLines.length === 0 ? (
            <pre className={LOG_OUTPUT_CLASSES}>
              {t("logs_empty")}
            </pre>
          ) : visibleLines.length === 0 ? (
            <PanelMessage>{t("logs_search_no_matches")}</PanelMessage>
          ) : (
            <pre className={LOG_OUTPUT_CLASSES}>
              {visibleLines.join("\n")}
            </pre>
          )}
        </div>
      ) : null}
    </div>
  )
}

// Split fetched log output into lines for client-side search. A trailing
// newline terminates the last line rather than adding a blank one.
function splitLogLines(log: string): string[] {
  if (!log) return []
  const lines = log.split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  return lines
}
