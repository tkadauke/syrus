import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesEndpoints,
  fetchKubernetesIngresses,
  fetchKubernetesServices,
  type KubernetesEndpointRow,
  type KubernetesIngressRow,
  type KubernetesServiceRow
} from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { Dropdown } from "../Dropdown"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { StatusBadge } from "../StatusBadge"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

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
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
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

  const visible = (services.data?.services ?? []).filter((service) =>
    matchesSearch(query, service.name, service.namespace, service.type, service.cluster_ip)
  )

  const open = (service: KubernetesServiceRow) =>
    detail.openDetail({
      kind: "service",
      kindLabel: t("network_kind_services"),
      name: service.name,
      namespace: service.namespace,
      fields: [
        { label: t("col_namespace"), value: service.namespace },
        { label: t("col_type"), value: service.type || "-" },
        { label: t("col_cluster_ip"), value: service.cluster_ip || "-" },
        {
          label: t("col_ports"),
          value: service.ports.length === 0 ? "-" : service.ports.map((port) => `${port.port}${port.protocol ? `/${port.protocol}` : ""}`).join(", ")
        },
        { label: t("col_age"), value: formatAge(service.created_at) }
      ]
    })

  return (
    <div aria-label={t("aria_services_tab")} className="space-y-3">
      {services.isPending ? <PanelMessage>{t("services_loading")}</PanelMessage> : null}
      {services.isError ? <PanelMessage tone="error">{errorMessage(services.error, t("services_error_loading"))}</PanelMessage> : null}
      {services.isSuccess ? (
        services.data.services.length === 0 ? (
          <PanelMessage>{t("services_empty")}</PanelMessage>
        ) : (
          <>
            <TableSearch onChange={setQuery} query={query} />
            {services.data.truncated ? <TruncatedNotice /> : null}
            {visible.length === 0 ? (
              <SearchNoMatches />
            ) : (
              <KubernetesResourceTable
                columns={serviceColumns(t, endpointsByKey, open)}
                defaultSort={{ column: "name", direction: "asc" }}
                empty={<PanelMessage>{t("services_empty")}</PanelMessage>}
                getRowKey={(service) => `${service.namespace}/${service.name}`}
                rows={visible}
                storageKey="syrus.k8s_cluster.services.columns"
                summary={t("tab_services")}
              />
            )}
          </>
        )
      ) : null}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </div>
  )
}

function serviceColumns(
  t: ReturnType<typeof useT>["t"],
  endpointsByKey: Map<string, KubernetesEndpointRow>,
  open: (service: KubernetesServiceRow) => void
): Array<KubernetesResourceTableColumn<KubernetesServiceRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (service) => <DetailNameButton name={service.name} onOpen={() => open(service)} />,
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

function IngressesTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const ingresses = useQuery({
    queryKey: [ "k8s_cluster", "ingresses", clusterId, namespace ],
    queryFn: () => fetchKubernetesIngresses(clusterId, namespace)
  })

  if (ingresses.isPending) return <PanelMessage>{t("ingresses_loading")}</PanelMessage>
  if (ingresses.isError) return <PanelMessage tone="error">{errorMessage(ingresses.error, t("ingresses_error_loading"))}</PanelMessage>
  if (ingresses.data.ingresses.length === 0) return <PanelMessage>{t("ingresses_empty")}</PanelMessage>

  const visible = ingresses.data.ingresses.filter((ingress) =>
    matchesSearch(query, ingress.name, ingress.namespace, ingress.ingress_class, ...ingress.hosts)
  )

  const open = (ingress: KubernetesIngressRow) =>
    detail.openDetail({
      kind: "ingress",
      kindLabel: t("network_kind_ingresses"),
      name: ingress.name,
      namespace: ingress.namespace,
      fields: [
        { label: t("col_namespace"), value: ingress.namespace },
        { label: t("col_hosts"), value: ingress.hosts.length === 0 ? "-" : ingress.hosts.join(", ") },
        { label: t("col_backend"), value: backendSummary(ingress) },
        { label: t("col_tls"), value: ingress.tls_hosts.length > 0 ? t("yes") : t("no") },
        { label: t("col_ingress_class"), value: ingress.ingress_class || "-" },
        { label: t("col_age"), value: formatAge(ingress.created_at) }
      ]
    })

  return (
    <>
      <TableSearch onChange={setQuery} query={query} />
      {ingresses.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <KubernetesResourceTable
          columns={ingressColumns(t, open)}
          defaultSort={{ column: "name", direction: "asc" }}
          empty={<PanelMessage>{t("ingresses_empty")}</PanelMessage>}
          getRowKey={(ingress) => `${ingress.namespace}/${ingress.name}`}
          rows={visible}
          storageKey="syrus.k8s_cluster.ingresses.columns"
          summary={t("network_kind_ingresses")}
        />
      )}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function ingressColumns(
  t: ReturnType<typeof useT>["t"],
  open: (ingress: KubernetesIngressRow) => void
): Array<KubernetesResourceTableColumn<KubernetesIngressRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (ingress) => <DetailNameButton name={ingress.name} onOpen={() => open(ingress)} />,
      required: true,
      sort: "name",
      sortValue: (ingress) => ingress.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (ingress) => ingress.namespace,
      sort: "namespace",
      sortValue: (ingress) => ingress.namespace
    },
    {
      key: "hosts",
      header: t("col_hosts"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      filterValue: (ingress) => ingress.hosts,
      render: (ingress) => (ingress.hosts.length === 0 ? "-" : ingress.hosts.join(", ")),
      sort: "hosts",
      sortValue: (ingress) => ingress.hosts[0] ?? null
    },
    {
      key: "backend",
      header: t("col_backend"),
      className: "font-mono text-gray-700 dark:text-gray-300",
      filterValue: (ingress) => backendSummary(ingress),
      render: (ingress) => backendSummary(ingress),
      sort: "backend",
      sortValue: (ingress) => backendSummary(ingress)
    },
    {
      key: "tls",
      header: t("col_tls"),
      filterValue: (ingress) => (ingress.tls_hosts.length > 0 ? t("yes") : t("no")),
      render: (ingress) => (
        <StatusBadge tone={ingress.tls_hosts.length > 0 ? "success" : "neutral"}>
          {ingress.tls_hosts.length > 0 ? t("yes") : t("no")}
        </StatusBadge>
      ),
      sort: "tls",
      sortValue: (ingress) => Number(ingress.tls_hosts.length > 0)
    },
    {
      key: "ingress_class",
      header: t("col_ingress_class"),
      className: "text-gray-700 dark:text-gray-300",
      render: (ingress) => ingress.ingress_class || "-",
      sort: "ingress_class",
      sortValue: (ingress) => ingress.ingress_class
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (ingress) => formatAge(ingress.created_at),
      sort: "created_at",
      sortValue: (ingress) => ingress.created_at
    }
  ]
}

// Flatten every rule path's backend Service/port so the operator can trace
// an external host to the Service that serves it without a second request.
function backendSummary(ingress: KubernetesIngressRow) {
  const backends = ingress.rules.flatMap((rule) =>
    rule.paths.map((path) => (path.service_name ? `${path.service_name}${path.service_port ? `:${path.service_port}` : ""}` : null))
  ).filter((backend): backend is string => backend !== null)

  return [...new Set(backends)].join(", ") || "-"
}
