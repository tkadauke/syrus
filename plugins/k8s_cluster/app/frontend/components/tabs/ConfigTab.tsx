import { useQuery } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { PanelMessage } from "@app/components/PanelMessage"
import { DataTable } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { fetchKubernetesConfigMaps, fetchKubernetesSecrets, type KubernetesConfigMapRow, type KubernetesSecretRow } from "../../api/kubernetesResources"
import { formatAge } from "../../lib/k8sFormat"
import { DetailNameButton, ResourceDetailDrawer, useResourceDetail } from "../ResourceDetailDrawer"

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
  const configMaps = useQuery({
    queryKey: ["k8s_cluster", "configmaps", clusterId, namespace],
    queryFn: () => fetchKubernetesConfigMaps(clusterId, namespace)
  })

  if (configMaps.isPending) return <PanelMessage>{t("config_loading_configmaps")}</PanelMessage>
  if (configMaps.isError) return <PanelMessage tone="error">{errorMessage(configMaps.error, t("config_error_loading_configmaps"))}</PanelMessage>
  if (configMaps.data.config_maps.length === 0) return <PanelMessage>{t("config_empty_configmaps")}</PanelMessage>

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
      <DataTable.Root density="compact">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_keys")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {configMaps.data.config_maps.map((configMap) => (
            <ExpandableKeyRow
              key={`${configMap.namespace}/${configMap.name}`}
              age={configMap.created_at}
              extraCells={null}
              keyNames={configMap.key_names}
              name={configMap.name}
              namespace={configMap.namespace}
              onOpen={() => open(configMap)}
            />
          ))}
        </DataTable.Body>
      </DataTable.Root>
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function SecretsTable({ clusterId, namespace }: { clusterId: number; namespace: string | null }) {
  const { t } = useT("k8s_cluster")
  const detail = useResourceDetail()
  const secrets = useQuery({
    queryKey: ["k8s_cluster", "secrets", clusterId, namespace],
    queryFn: () => fetchKubernetesSecrets(clusterId, namespace)
  })

  if (secrets.isPending) return <PanelMessage>{t("config_loading_secrets")}</PanelMessage>
  if (secrets.isError) return <PanelMessage tone="error">{errorMessage(secrets.error, t("config_error_loading_secrets"))}</PanelMessage>
  if (secrets.data.secrets.length === 0) return <PanelMessage>{t("config_empty_secrets")}</PanelMessage>

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
      <DataTable.Root density="compact">
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("col_name")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_namespace")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_type")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_keys")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_age")}</DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {secrets.data.secrets.map((secret) => (
            <ExpandableKeyRow
              key={`${secret.namespace}/${secret.name}`}
              age={secret.created_at}
              colSpan={5}
              extraCells={<DataTable.Cell className="text-text-secondary">{secret.type || "-"}</DataTable.Cell>}
              keyNames={secret.key_names}
              name={secret.name}
              namespace={secret.namespace}
              onOpen={() => open(secret)}
            />
          ))}
        </DataTable.Body>
      </DataTable.Root>
      <ResourceDetailDrawer clusterId={clusterId} onClose={detail.closeDetail} selection={detail.selection} />
    </>
  )
}

function ExpandableKeyRow({
  name,
  namespace,
  age,
  keyNames,
  extraCells,
  colSpan = 4,
  onOpen
}: {
  name: string
  namespace: string
  age: string | null
  keyNames: string[]
  extraCells: ReactNode
  colSpan?: number
  onOpen: () => void
}) {
  const { t } = useT("k8s_cluster")
  const [expanded, setExpanded] = useState(false)

  return (
    <>
      <DataTable.Row interactive key={`${namespace}/${name}`} onClick={onOpen}>
        <DataTable.Cell className="font-medium">
          <DetailNameButton name={name} onOpen={onOpen} />
        </DataTable.Cell>
        <DataTable.Cell className="text-text-secondary">{namespace}</DataTable.Cell>
        {extraCells}
        <DataTable.Cell className="text-text-secondary">
          {keyNames.length === 0 ? (
            "-"
          ) : (
            <button
              aria-expanded={expanded}
              className="underline decoration-dotted underline-offset-2"
              onClick={(event) => {
                event.stopPropagation()
                setExpanded((value) => !value)
              }}
              type="button"
            >
              {expanded ? t("config_hide_keys") : t("config_show_keys", { count: keyNames.length })}
            </button>
          )}
        </DataTable.Cell>
        <DataTable.Cell className="text-text-secondary">{formatAge(age)}</DataTable.Cell>
      </DataTable.Row>
      {expanded && keyNames.length > 0 ? (
        <DataTable.Row>
          <DataTable.Cell className="font-mono text-text-secondary" colSpan={colSpan}>
            {keyNames.join(", ")}
          </DataTable.Cell>
        </DataTable.Row>
      ) : null}
    </>
  )
}
