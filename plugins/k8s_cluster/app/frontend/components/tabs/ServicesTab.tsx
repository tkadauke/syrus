import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesEndpoints, fetchKubernetesServices, type KubernetesEndpointRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { StatusBadge } from "../StatusBadge"

export function ServicesTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const services = useQuery({
    queryKey: [ "k8s_cluster", "services", clusterId, namespace ],
    queryFn: () => fetchKubernetesServices(clusterId, namespace)
  })
  // Endpoints share their Service's (namespace, name) by core v1 API
  // convention - fetched alongside, not blocking the Services list on it:
  // a Service without a matching Endpoints row (e.g. ExternalName) is a
  // normal outcome, not an error, and an Endpoints fetch failure just
  // leaves the column showing "-" instead of failing the whole tab.
  const endpoints = useQuery({
    queryKey: [ "k8s_cluster", "endpoints", clusterId, namespace ],
    queryFn: () => fetchKubernetesEndpoints(clusterId, namespace)
  })
  const endpointsByKey = new Map<string, KubernetesEndpointRow>(
    (endpoints.data?.endpoints ?? []).map((endpoint) => [ `${endpoint.namespace}/${endpoint.name}`, endpoint ])
  )

  return (
    <div aria-label={t("aria_services_tab")}>
      {services.isPending ? <PanelMessage>{t("services_loading")}</PanelMessage> : null}
      {services.isError ? <PanelMessage tone="error">{errorMessage(services.error, t("services_error_loading"))}</PanelMessage> : null}
      {services.isSuccess ? (
        services.data.services.length === 0 ? (
          <PanelMessage>{t("services_empty")}</PanelMessage>
        ) : (
          <DataTable.Root density="compact">
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_type")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_cluster_ip")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_ports")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_endpoints")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
                {services.data.services.map((service) => {
                  const endpoint = endpointsByKey.get(`${service.namespace}/${service.name}`)

                  return (
                    <DataTable.Row key={`${service.namespace}/${service.name}`}>
                      <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">{service.name}</DataTable.Cell>
                      <DataTable.Cell className="text-gray-700 dark:text-gray-300">{service.namespace}</DataTable.Cell>
                      <DataTable.Cell className="text-gray-700 dark:text-gray-300">{service.type || "-"}</DataTable.Cell>
                      <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">{service.cluster_ip || "-"}</DataTable.Cell>
                      <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">
                        {service.ports.length === 0
                          ? "-"
                          : service.ports.map((port) => `${port.port}${port.protocol ? `/${port.protocol}` : ""}`).join(", ")}
                      </DataTable.Cell>
                      <DataTable.Cell>
                        {endpoint ? (
                          <StatusBadge tone={endpoint.not_ready_addresses > 0 ? "warning" : endpoint.ready_addresses > 0 ? "success" : "neutral"}>
                            {t("services_endpoints_ready", { ready: endpoint.ready_addresses, total: endpoint.ready_addresses + endpoint.not_ready_addresses })}
                          </StatusBadge>
                        ) : "-"}
                      </DataTable.Cell>
                      <DataTable.Cell className="text-gray-700 dark:text-gray-300">{formatAge(service.created_at)}</DataTable.Cell>
                    </DataTable.Row>
                  )
                })}
            </DataTable.Body>
          </DataTable.Root>
        )
      ) : null}
    </div>
  )
}
