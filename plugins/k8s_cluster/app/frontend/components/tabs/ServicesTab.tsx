import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
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
          <div className="overflow-x-auto rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
            <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
              <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
                <tr>
                  <th className="px-4 py-2">{t("col_name")}</th>
                  <th className="px-4 py-2">{t("col_namespace")}</th>
                  <th className="px-4 py-2">{t("col_type")}</th>
                  <th className="px-4 py-2">{t("col_cluster_ip")}</th>
                  <th className="px-4 py-2">{t("col_ports")}</th>
                  <th className="px-4 py-2">{t("col_endpoints")}</th>
                  <th className="px-4 py-2">{t("col_age")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
                {services.data.services.map((service) => {
                  const endpoint = endpointsByKey.get(`${service.namespace}/${service.name}`)

                  return (
                    <tr key={`${service.namespace}/${service.name}`}>
                      <td className="px-4 py-2 font-medium text-gray-900 dark:text-gray-100">{service.name}</td>
                      <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{service.namespace}</td>
                      <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{service.type || "-"}</td>
                      <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">{service.cluster_ip || "-"}</td>
                      <td className="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300">
                        {service.ports.length === 0
                          ? "-"
                          : service.ports.map((port) => `${port.port}${port.protocol ? `/${port.protocol}` : ""}`).join(", ")}
                      </td>
                      <td className="px-4 py-2">
                        {endpoint ? (
                          <StatusBadge tone={endpoint.not_ready_addresses > 0 ? "warning" : endpoint.ready_addresses > 0 ? "success" : "neutral"}>
                            {t("services_endpoints_ready", { ready: endpoint.ready_addresses, total: endpoint.ready_addresses + endpoint.not_ready_addresses })}
                          </StatusBadge>
                        ) : "-"}
                      </td>
                      <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(service.created_at)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )
      ) : null}
    </div>
  )
}
