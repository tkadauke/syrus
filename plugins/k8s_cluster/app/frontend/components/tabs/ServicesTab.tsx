import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesEndpoints,
  fetchKubernetesIngresses,
  fetchKubernetesServices,
  type KubernetesEndpointRow,
  type KubernetesIngressRow
} from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
import { StatusBadge } from "../StatusBadge"

type NetworkKind = "services" | "ingresses"

export function ServicesTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const [kind, setKind] = useState<NetworkKind>("services")

  const kindOptions = [
    { value: "services" as const, label: t("network_kind_services") },
    { value: "ingresses" as const, label: t("network_kind_ingresses") }
  ]

  return (
    <div aria-label={t("aria_services_tab")} className="space-y-3">
      <Dropdown ariaLabel={t("network_kind_label")} onChange={setKind} options={kindOptions} value={kind} />
      {kind === "services" ? <ServicesTable clusterId={clusterId} namespace={namespace} /> : null}
      {kind === "ingresses" ? <IngressesTable clusterId={clusterId} namespace={namespace} /> : null}
    </div>
  )
}

function ServicesTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
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

  if (services.isPending) return <PanelMessage>{t("services_loading")}</PanelMessage>
  if (services.isError) return <PanelMessage tone="error">{errorMessage(services.error, t("services_error_loading"))}</PanelMessage>
  if (services.data.services.length === 0) return <PanelMessage>{t("services_empty")}</PanelMessage>

  return (
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
}

function IngressesTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const ingresses = useQuery({
    queryKey: [ "k8s_cluster", "ingresses", clusterId, namespace ],
    queryFn: () => fetchKubernetesIngresses(clusterId, namespace)
  })

  if (ingresses.isPending) return <PanelMessage>{t("ingresses_loading")}</PanelMessage>
  if (ingresses.isError) return <PanelMessage tone="error">{errorMessage(ingresses.error, t("ingresses_error_loading"))}</PanelMessage>
  if (ingresses.data.ingresses.length === 0) return <PanelMessage>{t("ingresses_empty")}</PanelMessage>

  return (
    <DataTable.Root density="compact">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_hosts")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_backend")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_tls")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_ingress_class")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {ingresses.data.ingresses.map((ingress) => (
          <DataTable.Row key={`${ingress.namespace}/${ingress.name}`}>
            <DataTable.Cell className="font-medium">{ingress.name}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{ingress.namespace}</DataTable.Cell>
            <DataTable.Cell className="font-mono text-text-secondary">{ingress.hosts.length === 0 ? "-" : ingress.hosts.join(", ")}</DataTable.Cell>
            <DataTable.Cell className="font-mono text-text-secondary">{backendSummary(ingress)}</DataTable.Cell>
            <DataTable.Cell>
              <StatusBadge tone={ingress.tls_hosts.length > 0 ? "success" : "neutral"}>
                {ingress.tls_hosts.length > 0 ? t("yes") : t("no")}
              </StatusBadge>
            </DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{ingress.ingress_class || "-"}</DataTable.Cell>
            <DataTable.Cell className="text-text-secondary">{formatAge(ingress.created_at)}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

// Flatten every rule path's backend Service/port so the operator can trace
// an external host to the Service that serves it without a second request.
function backendSummary(ingress: KubernetesIngressRow) {
  const backends = ingress.rules.flatMap((rule) =>
    rule.paths.map((path) => (path.service_name ? `${path.service_name}${path.service_port ? `:${path.service_port}` : ""}` : null))
  ).filter((backend): backend is string => backend !== null)

  return [...new Set(backends)].join(", ") || "-"
}
