import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type FormEvent } from "react"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useConfirm } from "@app/hooks/useConfirm"
import { NoticeToast } from "@app/components/NoticeToast"
import { PanelMessage } from "@app/components/PanelMessage"
import { Button, DataTable, Form, Modal, Page } from "@app/components/ui"
import { errorMessage } from "@app/lib/errorMessage"
import {
  createKubernetesCluster,
  deleteKubernetesCluster,
  fetchKubernetesClusters,
  testDraftKubernetesCluster,
  testKubernetesCluster,
  updateKubernetesCluster,
  type KubernetesClusterInput,
  type KubernetesClusterRow,
  type KubernetesClusterTestResult
} from "../api/kubernetesClusters"
import { ClusterBrowser } from "../components/ClusterBrowser"
import { StatusBadge } from "../components/StatusBadge"

const queryKey = ["k8s_cluster", "clusters"] as const

type BrowseTarget = { clusterId: number; label: string }
type ConnectionModalState = { mode: "create" } | { mode: "edit"; cluster: KubernetesClusterRow }

const CONNECTION_MODAL_PANEL_CLASS =
  "flex max-h-[calc(100vh-2rem)] w-full max-w-3xl flex-col overflow-hidden rounded-[var(--radius-panel)] bg-surface shadow-[var(--shadow-panel)]"

const EMPTY_FORM: KubernetesClusterInput = {
  label: "",
  agentic_access_enabled: false,
  allow_writes: false,
  insecure_skip_tls_verify: false,
  kubeconfig: ""
}

export function KubernetesClusters() {
  const { t } = useT("k8s_cluster")
  usePageTitle(t("heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const [browsing, setBrowsing] = useState<BrowseTarget | null>(null)
  const [connectionModal, setConnectionModal] = useState<ConnectionModalState | null>(null)
  const clusters = useQuery({
    queryKey,
    queryFn: fetchKubernetesClusters
  })

  if (browsing) {
    return (
      <Page.Root aria-label={t("aria_page")} className="flex h-full flex-col overflow-hidden" gutter="responsive" size="wide">
        <ClusterBrowser clusterId={browsing.clusterId} label={browsing.label} onBack={() => setBrowsing(null)} />
      </Page.Root>
    )
  }

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      <Page.Header className="border-b border-border pb-4">
        <Page.HeadingGroup>
          <Page.Title>{t("heading")}</Page.Title>
          <Page.Description>{t("description")}</Page.Description>
        </Page.HeadingGroup>
        <Page.Actions>
          <Button onClick={() => setConnectionModal({ mode: "create" })} type="button" variant="primary">
            {t("create_button")}
          </Button>
        </Page.Actions>
      </Page.Header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {clusters.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {clusters.isError ? <PanelMessage tone="error">{errorMessage(clusters.error, t("error_loading"))}</PanelMessage> : null}
      {clusters.isSuccess ? (
        <>
          <ClustersTable
            clusters={clusters.data.kubernetes_clusters}
            onBrowse={(cluster) => setBrowsing({ clusterId: cluster.id, label: cluster.label })}
            onEdit={(cluster) => setConnectionModal({ mode: "edit", cluster })}
            onNotice={setNotice}
          />
          {connectionModal ? (
            <ClusterConnectionModal
              key={connectionModal.mode === "edit" ? `edit-${connectionModal.cluster.id}` : "create"}
              modal={connectionModal}
              onClose={() => setConnectionModal(null)}
              onNotice={setNotice}
            />
          ) : null}
        </>
      ) : null}
    </Page.Root>
  )
}

function ClusterConnectionModal({
  modal,
  onClose,
  onNotice
}: {
  modal: ConnectionModalState
  onClose: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")
  const queryClient = useQueryClient()
  const editing = modal.mode === "edit"
  const cluster = editing ? modal.cluster : null
  const [values, setValues] = useState<KubernetesClusterInput>(
    cluster
      ? {
          label: cluster.label,
          agentic_access_enabled: cluster.agentic_access_enabled,
          allow_writes: cluster.allow_writes,
          insecure_skip_tls_verify: cluster.insecure_skip_tls_verify,
          kubeconfig: ""
        }
      : EMPTY_FORM
  )
  const create = useMutation({
    mutationFn: () => createKubernetesCluster(values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("created_notice", { label: payload.kubernetes_cluster.label }))
      onClose()
    }
  })
  const update = useMutation({
    mutationFn: () => updateKubernetesCluster(cluster?.id ?? 0, values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("updated_notice", { label: payload.kubernetes_cluster.label }))
      onClose()
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    if (editing) {
      update.mutate()
    } else {
      create.mutate()
    }
  }

  const busy = create.isPending || update.isPending
  const error = create.error ?? update.error
  const fallback = editing ? t("update_error_fallback") : t("create_error_fallback")
  const title = editing ? t("edit_heading") : t("add_heading")

  return (
    <Modal className={CONNECTION_MODAL_PANEL_CLASS} label={title} onClose={onClose} open>
      <form className="flex min-h-0 flex-col" onSubmit={submit}>
        <div className="border-b border-border px-5 py-4">
          <h2 className="text-lg font-semibold text-text-primary">{title}</h2>
        </div>
        <div className="min-h-0 overflow-y-auto px-5 py-4">
          <ClusterFieldsGrid
            idPrefix={editing ? `edit-cluster-${cluster?.id}` : "new-cluster"}
            kubeconfigHint={editing ? t("field_kubeconfig_hint_edit") : undefined}
            kubeconfigRequired={!editing}
            onChange={setValues}
            values={values}
          />
          {error ? (
            <p className="mt-3 text-sm text-danger-text" role="alert">
              {errorMessage(error, fallback)}
            </p>
          ) : null}
        </div>
        <Form.Actions align="start" className="border-t border-border px-5 py-4">
          <Button disabled={busy} type="submit" variant="primary">
            {busy ? (editing ? t("saving") : t("creating")) : editing ? t("save_button") : t("create_button")}
          </Button>
          <Button onClick={onClose} type="button" variant="secondary">
            {t("cancel_button")}
          </Button>
          <TestButton
            onTest={() => (editing && cluster ? testKubernetesCluster(cluster.id, values.kubeconfig || undefined) : testDraftKubernetesCluster(values))}
          />
        </Form.Actions>
      </form>
    </Modal>
  )
}

function ClustersTable({
  clusters,
  onBrowse,
  onEdit,
  onNotice
}: {
  clusters: KubernetesClusterRow[]
  onBrowse: (cluster: KubernetesClusterRow) => void
  onEdit: (cluster: KubernetesClusterRow) => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")

  return (
    <section>
      <DataTable.Root>
        <DataTable.Header>
          <DataTable.Row>
            <DataTable.HeadCell>{t("col_label")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_api_server_url")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_credential_kind")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_agentic_access")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_allow_writes")}</DataTable.HeadCell>
            <DataTable.HeadCell>{t("col_insecure_skip_tls_verify")}</DataTable.HeadCell>
            <DataTable.HeadCell>
              <span className="sr-only">{t("col_actions")}</span>
            </DataTable.HeadCell>
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {clusters.length === 0 ? (
            <DataTable.Empty colSpan={7}>{t("empty")}</DataTable.Empty>
          ) : (
            clusters.map((cluster) => (
              <ClusterRow cluster={cluster} key={cluster.id} onBrowse={() => onBrowse(cluster)} onEdit={() => onEdit(cluster)} onNotice={onNotice} />
            ))
          )}
        </DataTable.Body>
      </DataTable.Root>
    </section>
  )
}

function ClusterRow({
  cluster,
  onBrowse,
  onEdit,
  onNotice
}: {
  cluster: KubernetesClusterRow
  onBrowse: () => void
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")

  return (
    <DataTable.Row>
      <DataTable.Cell className="font-medium text-gray-900 dark:text-gray-100">{cluster.label}</DataTable.Cell>
      <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">{cluster.api_server_url}</DataTable.Cell>
      <DataTable.Cell className="text-gray-700 dark:text-gray-300">
        {cluster.credential_kind === "token"
          ? t("credential_kind_token")
          : cluster.credential_kind === "client_cert"
            ? t("credential_kind_client_cert")
            : t("credential_kind_none")}
      </DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={cluster.agentic_access_enabled ? "success" : "neutral"}>
          {cluster.agentic_access_enabled ? t("agentic_enabled") : t("agentic_disabled")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={cluster.allow_writes ? "warning" : "neutral"}>
          {cluster.allow_writes ? t("allow_writes_enabled") : t("allow_writes_disabled")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <StatusBadge tone={cluster.insecure_skip_tls_verify ? "warning" : "neutral"}>
          {cluster.insecure_skip_tls_verify ? t("insecure_enabled") : t("insecure_disabled")}
        </StatusBadge>
      </DataTable.Cell>
      <DataTable.Cell>
        <ClusterActions cluster={cluster} onBrowse={onBrowse} onEdit={onEdit} onNotice={onNotice} />
      </DataTable.Cell>
    </DataTable.Row>
  )
}

function ClusterActions({
  cluster,
  onBrowse,
  onEdit,
  onNotice
}: {
  cluster: KubernetesClusterRow
  onBrowse: () => void
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const destroy = useMutation({
    mutationFn: () => deleteKubernetesCluster(cluster.id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("deleted_notice", { label: cluster.label }))
    }
  })

  return (
    <div>
      <div className="flex flex-wrap items-start justify-end gap-2">
        <Button onClick={onBrowse} type="button" variant="primary">
          {t("browse_button")}
        </Button>
        <TestButton onTest={() => testKubernetesCluster(cluster.id)} />
        <Button onClick={onEdit} type="button" variant="secondary">
          {t("edit_button")}
        </Button>
        <Button
          disabled={destroy.isPending}
          onClick={async () => {
            if (await confirm({ message: t("confirm_delete", { label: cluster.label }), destructive: true })) {
              onNotice(null)
              destroy.mutate()
            }
          }}
          type="button"
          variant="danger"
        >
          {destroy.isPending ? t("deleting") : t("delete_button")}
        </Button>
      </div>
      {destroy.isError ? (
        <p className="mt-2 text-right text-xs text-danger-text" role="alert">
          {errorMessage(destroy.error, t("delete_error_fallback"))}
        </p>
      ) : null}
      {dialog}
    </div>
  )
}

function ClusterFieldsGrid({
  idPrefix,
  kubeconfigHint,
  kubeconfigRequired,
  onChange,
  values
}: {
  idPrefix: string
  kubeconfigHint?: string
  kubeconfigRequired?: boolean
  onChange: (values: KubernetesClusterInput) => void
  values: KubernetesClusterInput
}) {
  const { t } = useT("k8s_cluster")

  function set<K extends keyof KubernetesClusterInput>(key: K, value: KubernetesClusterInput[K]) {
    onChange({ ...values, [key]: value })
  }

  return (
    <div className="grid gap-3">
      <Form.Field controlId={`${idPrefix}-label`}>
        <Form.Label>{t("field_label")}</Form.Label>
        <Form.Input onChange={(event) => set("label", event.target.value)} required type="text" value={values.label} />
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-kubeconfig`}>
        <Form.Label>{t("field_kubeconfig")}</Form.Label>
        <Form.Textarea
          className="font-mono text-xs"
          onChange={(event) => set("kubeconfig", event.target.value)}
          placeholder={t("field_kubeconfig_placeholder")}
          required={kubeconfigRequired}
          rows={6}
          value={values.kubeconfig ?? ""}
        />
        {kubeconfigHint ? <Form.HelpText>{kubeconfigHint}</Form.HelpText> : null}
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-agentic-access`}>
        <Form.Checkbox
          checked={values.agentic_access_enabled}
          className="mt-0.5"
          label={t("field_agentic_access")}
          onChange={(event) => set("agentic_access_enabled", event.target.checked)}
        />
        <Form.HelpText>{t("field_agentic_access_hint")}</Form.HelpText>
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-allow-writes`}>
        <Form.Checkbox
          checked={values.allow_writes}
          className="mt-0.5"
          label={t("field_allow_writes")}
          onChange={(event) => set("allow_writes", event.target.checked)}
        />
        <Form.HelpText>{t("field_allow_writes_hint")}</Form.HelpText>
      </Form.Field>
      <Form.Field controlId={`${idPrefix}-insecure`}>
        <Form.Checkbox
          checked={values.insecure_skip_tls_verify}
          className="mt-0.5"
          label={t("field_insecure_skip_tls_verify")}
          onChange={(event) => set("insecure_skip_tls_verify", event.target.checked)}
        />
        <Form.HelpText>{t("field_insecure_skip_tls_verify_hint")}</Form.HelpText>
      </Form.Field>
    </div>
  )
}

function TestButton({ onTest }: { onTest: () => Promise<KubernetesClusterTestResult> }) {
  const { t } = useT("k8s_cluster")
  const test = useMutation({ mutationFn: onTest })

  return (
    <div className="flex flex-col items-start gap-1">
      <Button disabled={test.isPending} onClick={() => test.mutate()} type="button" variant="secondary">
        {test.isPending ? t("testing") : t("test_button")}
      </Button>
      {test.isSuccess ? (
        test.data.success ? (
          <p className="text-xs text-emerald-700 dark:text-emerald-300">{t("test_success")}</p>
        ) : (
          <p className="text-xs text-danger-text">{t("test_failure", { error: test.data.error || "" })}</p>
        )
      ) : null}
      {test.isError ? <p className="text-xs text-danger-text">{errorMessage(test.error, t("test_error_fallback"))}</p> : null}
    </div>
  )
}

export default KubernetesClusters
