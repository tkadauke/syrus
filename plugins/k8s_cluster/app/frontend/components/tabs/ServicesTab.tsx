import { useQuery } from "@tanstack/react-query"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesServices } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Panel } from "../Panel"

export function ServicesTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const services = useQuery({
    queryKey: [ "k8s_cluster", "services", clusterId, namespace ],
    queryFn: () => fetchKubernetesServices(clusterId, namespace)
  })

  return (
    <div aria-label={t("aria_services_tab")}>
      {services.isPending ? <Panel>{t("services_loading")}</Panel> : null}
      {services.isError ? <Panel tone="error">{errorMessage(services.error, t("services_error_loading"))}</Panel> : null}
      {services.isSuccess ? (
        services.data.services.length === 0 ? (
          <Panel>{t("services_empty")}</Panel>
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
                  <th className="px-4 py-2">{t("col_age")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
                {services.data.services.map((service) => (
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
                    <td className="px-4 py-2 text-gray-700 dark:text-gray-300">{formatAge(service.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      ) : null}
    </div>
  )
}
