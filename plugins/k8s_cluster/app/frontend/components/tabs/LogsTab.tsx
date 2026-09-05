import { useQuery } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { Button } from "@app/components/Button"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesPodLogs, fetchKubernetesPods } from "../../api/kubernetesResources"
import { Dropdown } from "../Dropdown"

export function LogsTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const [selectedPodKey, setSelectedPodKey] = useState<string | null>(null)
  const [selectedContainer, setSelectedContainer] = useState<string | null>(null)

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
    queryKey: [ "k8s_cluster", "pod_logs", clusterId, selectedPod?.namespace, selectedPod?.name, selectedContainer ],
    queryFn: () => fetchKubernetesPodLogs(clusterId, selectedPod!.namespace, selectedPod!.name, { container: selectedContainer }),
    enabled: !!selectedPod
  })

  if (pods.isPending) return <PanelMessage>{t("logs_loading_pods")}</PanelMessage>
  if (pods.isError) return <PanelMessage tone="error">{errorMessage(pods.error, t("logs_error_loading_pods"))}</PanelMessage>

  if (pods.data.pods.length === 0) {
    return <PanelMessage>{t("logs_no_pods")}</PanelMessage>
  }

  const podOptions = pods.data.pods.map((pod) => ({ value: `${pod.namespace}/${pod.name}`, label: `${pod.namespace}/${pod.name}` }))
  const containerOptions = (selectedPod?.container_names ?? []).map((name) => ({ value: name, label: name }))

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
          <Button onClick={() => void logs.refetch()} size="sm" variant="secondary">
            {t("logs_refresh")}
          </Button>
        ) : null}
      </div>

      {!selectedPod ? <PanelMessage>{t("logs_select_pod")}</PanelMessage> : null}
      {selectedPod && logs.isPending ? <PanelMessage>{t("logs_loading")}</PanelMessage> : null}
      {selectedPod && logs.isError ? <PanelMessage tone="error">{errorMessage(logs.error, t("logs_error_loading"))}</PanelMessage> : null}
      {selectedPod && logs.isSuccess ? (
        <pre className="max-h-[32rem] overflow-auto rounded border border-gray-200 dark:border-gray-800 bg-gray-950 p-3 text-xs text-gray-100">
          {logs.data.log || t("logs_empty")}
        </pre>
      ) : null}
    </div>
  )
}
