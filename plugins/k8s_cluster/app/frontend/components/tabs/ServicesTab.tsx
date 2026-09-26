import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEndpoints, fetchKubernetesServices, type KubernetesEndpointRow, type KubernetesServiceRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { StatusBadge } from "../StatusBadge"

export function ServicesTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const services = useQuery({
    queryKey: ["k8s_cluster", "services", clusterId, namespace],
    queryFn: () => fetchKubernetesServices(clusterId, namespace)
  })
  // Endpoints share their Service's (namespace, name) by core v1 API
  // convention - fetched alongside, not blocking the Services list on it:
  // a Service without a matching Endpoints row (e.g. ExternalName) is a
  // normal outcome, not an error, and an Endpoints fetch failure just
  // leaves the column showing "-" instead of failing the whole tab.
  const endpoints = useQuery({
    queryKey: ["k8s_cluster", "endpoints", clusterId, namespace],
    queryFn: () => fetchKubernetesEndpoints(clusterId, namespace)
  })
  const endpointsByKey = new Map<string, KubernetesEndpointRow>(
    (endpoints.data?.endpoints ?? []).map((endpoint) => [`${endpoint.namespace}/${endpoint.name}`, endpoint])
  )

  return (
    <div aria-label={t("aria_services_tab")}>
      {services.isPending ? <PanelMessage>{t("services_loading")}</PanelMessage> : null}
      {services.isError ? <PanelMessage tone="error">{errorMessage(services.error, t("services_error_loading"))}</PanelMessage> : null}
      {services.isSuccess ? (
        services.data.services.length === 0 ? (
          <PanelMessage>{t("services_empty")}</PanelMessage>
        ) : (
          <KubernetesResourceTable
            columns={serviceColumns(t, endpointsByKey)}
            defaultSort={{ column: "name", direction: "asc" }}
            empty={<PanelMessage>{t("services_empty")}</PanelMessage>}
            getRowKey={(service) => `${service.namespace}/${service.name}`}
            rows={services.data.services}
            storageKey="syrus.k8s_cluster.services.columns"
            summary={t("tab_services")}
          />
        )
      ) : null}
    </div>
  )
}

function serviceColumns(
  t: ReturnType<typeof useT>["t"],
  endpointsByKey: Map<string, KubernetesEndpointRow>
): Array<KubernetesResourceTableColumn<KubernetesServiceRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (service) => service.name,
      required: true,
      sort: "name",
      sortValue: (service) => service.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (service) => service.namespace,
      sort: "namespace",
      sortValue: (service) => service.namespace
    },
    {
      key: "type",
      header: t("col_type"),
      className: "text-gray-700 dark:text-gray-300",
      render: (service) => service.type || "-",
      sort: "type",
      sortValue: (service) => service.type
    },
    {
      key: "cluster_ip",
      header: t("col_cluster_ip"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      render: (service) => service.cluster_ip || "-",
      sort: "cluster_ip",
      sortValue: (service) => service.cluster_ip
    },
    {
      key: "ports",
      header: t("col_ports"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      filterValue: (service) => service.ports.map((port) => `${port.port}${port.protocol ? `/${port.protocol}` : ""}`),
      render: (service) =>
        service.ports.length === 0 ? "-" : service.ports.map((port) => `${port.port}${port.protocol ? `/${port.protocol}` : ""}`).join(", ")
    },
    {
      key: "endpoints",
      header: t("col_endpoints"),
      filterValue: (service) => endpointLabel(t, endpointsByKey.get(`${service.namespace}/${service.name}`)),
      render: (service) => {
        const endpoint = endpointsByKey.get(`${service.namespace}/${service.name}`)
        return endpoint ? (
          <StatusBadge tone={endpoint.not_ready_addresses > 0 ? "warning" : endpoint.ready_addresses > 0 ? "success" : "neutral"}>
            {endpointLabel(t, endpoint)}
          </StatusBadge>
        ) : (
          "-"
        )
      },
      sort: "endpoints",
      sortValue: (service) => endpointsByKey.get(`${service.namespace}/${service.name}`)?.ready_addresses ?? null
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (service) => formatAge(service.created_at),
      sort: "created_at",
      sortValue: (service) => service.created_at
    }
  ]
}

function endpointLabel(t: ReturnType<typeof useT>["t"], endpoint: KubernetesEndpointRow | undefined) {
  return endpoint ? t("services_endpoints_ready", { ready: endpoint.ready_addresses, total: endpoint.ready_addresses + endpoint.not_ready_addresses }) : "-"
}
