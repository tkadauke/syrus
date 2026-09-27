import { useQuery } from "@tanstack/react-query"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesConfigMaps, fetchKubernetesSecrets, type KubernetesConfigMapRow, type KubernetesSecretRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { KubernetesResourceTable, type KubernetesResourceTableColumn } from "../KubernetesResourceTable"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"
import { SearchNoMatches, TableSearch, TruncatedNotice, matchesSearch, useTableSearch } from "../TableTools"

export function ConfigTab({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")

  return (
    <div aria-label={t("aria_config_tab")} className="space-y-3">
      <section aria-label={t("config_section_configmaps")}>
        <ConfigMapsTable clusterId={clusterId} namespace={namespace} />
      </section>
      <section aria-label={t("config_section_secrets")}>
        <p className="mb-2 text-[length:var(--text-caption)] text-text-muted">{t("config_secrets_redacted_note")}</p>
        <SecretsTable clusterId={clusterId} namespace={namespace} />
      </section>
    </div>
  )
}

function ConfigMapsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const configMaps = useQuery({
    queryKey: ["k8s_cluster", "configmaps", clusterId, namespace],
    queryFn: () => fetchKubernetesConfigMaps(clusterId, namespace)
  })

  if (configMaps.isPending) return <PanelMessage>{t("config_loading_configmaps")}</PanelMessage>
  if (configMaps.isError) return <PanelMessage tone="error">{errorMessage(configMaps.error, t("config_error_loading_configmaps"))}</PanelMessage>
  if (configMaps.data.config_maps.length === 0) return <PanelMessage>{t("config_empty_configmaps")}</PanelMessage>

  const visible = configMaps.data.config_maps.filter((configMap) =>
    matchesSearch(query, configMap.name, configMap.namespace, ...configMap.key_names)
  )

  const open = (configMap: KubernetesConfigMapRow) =>
    detail.openDetail({
      kind: "configmap",
      kindLabel: t("config_section_configmaps"),
      name: configMap.name,
      namespace: configMap.namespace,
      fields: [
        { label: t("col_namespace"), value: configMap.namespace },
        { label: t("col_keys"), value: String(configMap.key_count) },
        { label: t("col_age"), value: formatAge(configMap.created_at) }
      ]
    })

  return (
    <>
      <TableSearch onChange={setQuery} query={query} />
      {configMaps.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <KubernetesResourceTable
          columns={configMapColumns(t, open)}
          defaultSort={{ column: "name", direction: "asc" }}
          empty={<PanelMessage>{t("config_empty_configmaps")}</PanelMessage>}
          getRowKey={(configMap) => `${configMap.namespace}/${configMap.name}`}
          renderExpanded={(configMap) => <ExpandedKeyNames keyNames={configMap.key_names} />}
          rows={visible}
          storageKey="syrus.k8s_cluster.config_maps.columns"
          summary={t("config_section_configmaps")}
        />
      )}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function SecretsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const { query, setQuery } = useTableSearch()
  const secrets = useQuery({
    queryKey: ["k8s_cluster", "secrets", clusterId, namespace],
    queryFn: () => fetchKubernetesSecrets(clusterId, namespace)
  })

  if (secrets.isPending) return <PanelMessage>{t("config_loading_secrets")}</PanelMessage>
  if (secrets.isError) return <PanelMessage tone="error">{errorMessage(secrets.error, t("config_error_loading_secrets"))}</PanelMessage>
  if (secrets.data.secrets.length === 0) return <PanelMessage>{t("config_empty_secrets")}</PanelMessage>

  const visible = secrets.data.secrets.filter((secret) =>
    matchesSearch(query, secret.name, secret.namespace, secret.type, ...secret.key_names)
  )

  const open = (secret: KubernetesSecretRow) =>
    detail.openDetail({
      kind: "secret",
      kindLabel: t("config_section_secrets"),
      name: secret.name,
      namespace: secret.namespace,
      fields: [
        { label: t("col_namespace"), value: secret.namespace },
        { label: t("col_type"), value: secret.type || "-" },
        { label: t("col_keys"), value: String(secret.key_count) },
        { label: t("col_age"), value: formatAge(secret.created_at) }
      ]
    })

  return (
    <>
      <TableSearch onChange={setQuery} query={query} />
      {secrets.data.truncated ? <TruncatedNotice /> : null}
      {visible.length === 0 ? (
        <SearchNoMatches />
      ) : (
        <KubernetesResourceTable
          columns={secretColumns(t, open)}
          defaultSort={{ column: "name", direction: "asc" }}
          empty={<PanelMessage>{t("config_empty_secrets")}</PanelMessage>}
          getRowKey={(secret) => `${secret.namespace}/${secret.name}`}
          renderExpanded={(secret) => <ExpandedKeyNames keyNames={secret.key_names} />}
          rows={visible}
          storageKey="syrus.k8s_cluster.secrets.columns"
          summary={t("config_section_secrets")}
        />
      )}
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function configMapColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (configMap: KubernetesConfigMapRow) => void
): Array<KubernetesResourceTableColumn<KubernetesConfigMapRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (configMap) => <DetailNameButton name={configMap.name} onOpen={() => onOpen(configMap)} />,
      required: true,
      sort: "name",
      sortValue: (configMap) => configMap.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (configMap) => configMap.namespace,
      sort: "namespace",
      sortValue: (configMap) => configMap.namespace
    },
    {
      key: "keys",
      header: t("col_keys"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (configMap) => configMap.key_names,
      render: (configMap, { expanded, toggleExpanded }) => <KeyNamesToggle expanded={expanded} keyNames={configMap.key_names} onToggle={toggleExpanded} />,
      sort: "keys",
      sortValue: (configMap) => configMap.key_count
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (configMap) => formatAge(configMap.created_at),
      sort: "created_at",
      sortValue: (configMap) => configMap.created_at
    }
  ]
}

function secretColumns(
  t: ReturnType<typeof useT>["t"],
  onOpen: (secret: KubernetesSecretRow) => void
): Array<KubernetesResourceTableColumn<KubernetesSecretRow>> {
  return [
    {
      key: "name",
      header: t("col_name"),
      className: "font-medium text-gray-900 dark:text-gray-100",
      render: (secret) => <DetailNameButton name={secret.name} onOpen={() => onOpen(secret)} />,
      required: true,
      sort: "name",
      sortValue: (secret) => secret.name
    },
    {
      key: "namespace",
      header: t("col_namespace"),
      className: "text-gray-700 dark:text-gray-300",
      render: (secret) => secret.namespace,
      sort: "namespace",
      sortValue: (secret) => secret.namespace
    },
    {
      key: "type",
      header: t("col_type"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (secret) => secret.type,
      render: (secret) => secret.type || "-",
      sort: "type",
      sortValue: (secret) => secret.type
    },
    {
      key: "keys",
      header: t("col_keys"),
      className: "text-gray-700 dark:text-gray-300",
      filterValue: (secret) => secret.key_names,
      render: (secret, { expanded, toggleExpanded }) => <KeyNamesToggle expanded={expanded} keyNames={secret.key_names} onToggle={toggleExpanded} />,
      sort: "keys",
      sortValue: (secret) => secret.key_count
    },
    {
      key: "created_at",
      header: t("col_age"),
      className: "text-gray-700 dark:text-gray-300",
      render: (secret) => formatAge(secret.created_at),
      sort: "created_at",
      sortValue: (secret) => secret.created_at
    }
  ]
}

function KeyNamesToggle({ keyNames, expanded, onToggle }: { keyNames: string[]; expanded: boolean; onToggle: () => void }) {
  const { t } = useT("k8s_cluster")

  if (keyNames.length === 0) return <>-</>

  return (
    <button aria-expanded={expanded} className="underline decoration-dotted underline-offset-2" onClick={() => onToggle()} type="button">
      {expanded ? t("config_hide_keys") : t("config_show_keys", { count: keyNames.length })}
    </button>
  )
}

function ExpandedKeyNames({ keyNames }: { keyNames: string[] }) {
  if (keyNames.length === 0) return null

  return <span className="font-mono text-xs text-text-secondary">{keyNames.join(", ")}</span>
}
