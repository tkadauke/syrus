import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { Button } from "@app/components/Button"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesNamespaces } from "../api/kubernetesResources"
import { Dropdown } from "./Dropdown"
import { Panel } from "./Panel"
import { EventsTab } from "./tabs/EventsTab"
import { LiveTab } from "./tabs/LiveTab"
import { LogsTab } from "./tabs/LogsTab"
import { NodesTab } from "./tabs/NodesTab"
import { OverviewTab } from "./tabs/OverviewTab"
import { ServicesTab } from "./tabs/ServicesTab"
import { StorageTab } from "./tabs/StorageTab"
import { WorkloadsTab } from "./tabs/WorkloadsTab"

const ALL_NAMESPACES = ""

type ClusterTab = "overview" | "workloads" | "services" | "storage" | "nodes" | "events" | "logs" | "live"

const NAMESPACE_SCOPED_TABS: ClusterTab[] = [ "workloads", "services", "storage", "events", "logs" ]

export function ClusterBrowser({ clusterId, label, onBack }: { clusterId: number; label: string; onBack: () => void }) {
  const { t } = useT("k8s_cluster")
  const [tab, setTab] = useState<ClusterTab>("overview")
  const [namespace, setNamespace] = useState<string>(ALL_NAMESPACES)

  const tabOptions = [
    { value: "overview" as const, label: t("tab_overview") },
    { value: "workloads" as const, label: t("tab_workloads") },
    { value: "services" as const, label: t("tab_services") },
    { value: "storage" as const, label: t("tab_storage") },
    { value: "nodes" as const, label: t("tab_nodes") },
    { value: "events" as const, label: t("tab_events") },
    { value: "logs" as const, label: t("tab_logs") },
    { value: "live" as const, label: t("tab_live") }
  ]

  const effectiveNamespace = namespace === ALL_NAMESPACES ? null : namespace

  return (
    <section className="flex h-full min-h-0 flex-col gap-4">
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("browse_heading", { label })}</h1>
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("browse_description")}</p>
        </div>
        <Button onClick={onBack} size="sm" variant="secondary">
          {t("back_to_clusters")}
        </Button>
      </div>

      <div className="flex shrink-0 flex-wrap items-center gap-2">
        <Dropdown ariaLabel={t("tab_switcher_label")} onChange={setTab} options={tabOptions} value={tab} />
        {NAMESPACE_SCOPED_TABS.includes(tab) ? (
          <NamespacePicker clusterId={clusterId} namespace={namespace} onChange={setNamespace} />
        ) : null}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {tab === "overview" ? <OverviewTab clusterId={clusterId} /> : null}
        {tab === "workloads" ? <WorkloadsTab clusterId={clusterId} namespace={effectiveNamespace} /> : null}
        {tab === "services" ? <ServicesTab clusterId={clusterId} namespace={effectiveNamespace} /> : null}
        {tab === "storage" ? <StorageTab clusterId={clusterId} namespace={effectiveNamespace} /> : null}
        {tab === "nodes" ? <NodesTab clusterId={clusterId} /> : null}
        {tab === "events" ? <EventsTab clusterId={clusterId} namespace={effectiveNamespace} /> : null}
        {tab === "logs" ? <LogsTab clusterId={clusterId} namespace={effectiveNamespace} /> : null}
        {tab === "live" ? <LiveTab clusterId={clusterId} /> : null}
      </div>
    </section>
  )
}

function NamespacePicker({
  clusterId,
  namespace,
  onChange
}: {
  clusterId: number
  namespace: string
  onChange: (namespace: string) => void
}) {
  const { t } = useT("k8s_cluster")
  const namespaces = useQuery({
    queryKey: [ "k8s_cluster", "namespaces", clusterId ],
    queryFn: () => fetchKubernetesNamespaces(clusterId)
  })

  if (namespaces.isPending) return <Panel>{t("namespace_loading")}</Panel>
  if (namespaces.isError) return <Panel tone="error">{errorMessage(namespaces.error, t("namespace_error_loading"))}</Panel>

  const options = [
    { value: ALL_NAMESPACES, label: t("all_namespaces") },
    ...namespaces.data.namespaces.map((ns) => ({ value: ns.name, label: ns.name }))
  ]

  return <Dropdown ariaLabel={t("namespace_filter_label")} onChange={onChange} options={options} value={namespace} />
}
