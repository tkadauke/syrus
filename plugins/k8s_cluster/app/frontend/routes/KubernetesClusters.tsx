import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type FormEvent, type ReactNode } from "react"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { NoticeToast } from "@app/components/NoticeToast"
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

const queryKey = ["k8s_cluster", "clusters"] as const

const EMPTY_FORM: KubernetesClusterInput = {
  label: "",
  agentic_access_enabled: false,
  allow_writes: false,
  insecure_skip_tls_verify: false,
  kubeconfig: ""
}

const INPUT_CLASSES = "mt-1 block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm normal-case text-gray-700 dark:text-gray-300"
const TEXTAREA_CLASSES = `${INPUT_CLASSES} font-mono text-xs`

export function KubernetesClusters() {
  const { t } = useT("k8s_cluster")
  usePageTitle(t("heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const clusters = useQuery({
    queryKey,
    queryFn: fetchKubernetesClusters
  })

  return (
    <main aria-label={t("aria_page")} className="mx-auto flex h-full max-w-[72rem] flex-col gap-6 overflow-hidden p-3 sm:p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("heading")}</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("description")}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {clusters.isPending ? <Panel>{t("loading")}</Panel> : null}
      {clusters.isError ? <Panel tone="error">{errorMessage(clusters.error, t("error_loading"))}</Panel> : null}
      {clusters.isSuccess ? (
        <>
          <ClusterCreateForm onNotice={setNotice} />
          <ClustersTable clusters={clusters.data.kubernetes_clusters} onNotice={setNotice} />
        </>
      ) : null}
    </main>
  )
}

function ClusterCreateForm({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("k8s_cluster")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<KubernetesClusterInput>(EMPTY_FORM)
  const create = useMutation({
    mutationFn: () => createKubernetesCluster(values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("created_notice", { label: payload.kubernetes_cluster.label }))
      setValues(EMPTY_FORM)
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950 p-4">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("add_heading")}</h2>
      <form className="mt-3 space-y-3" onSubmit={submit}>
        <ClusterFieldsGrid idPrefix="new-cluster" kubeconfigRequired onChange={setValues} values={values} />
        <div className="flex flex-wrap items-center gap-3">
          <button
            className="rounded bg-brand px-3 py-1.5 text-sm font-medium text-on-brand hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
            disabled={create.isPending}
            type="submit"
          >
            {create.isPending ? t("creating") : t("create_button")}
          </button>
          <TestButton onTest={() => testDraftKubernetesCluster(values)} />
        </div>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, t("create_error_fallback"))}</p> : null}
    </section>
  )
}

function ClustersTable({
  clusters,
  onNotice
}: {
  clusters: KubernetesClusterRow[]
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")
  const [editingId, setEditingId] = useState<number | null>(null)

  return (
    <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-950">
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-800 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-900 text-left text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("col_label")}</th>
              <th className="px-4 py-2">{t("col_api_server_url")}</th>
              <th className="px-4 py-2">{t("col_credential_kind")}</th>
              <th className="px-4 py-2">{t("col_agentic_access")}</th>
              <th className="px-4 py-2">{t("col_allow_writes")}</th>
              <th className="px-4 py-2">{t("col_insecure_skip_tls_verify")}</th>
              <th className="px-4 py-2"><span className="sr-only">{t("col_actions")}</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-900">
            {clusters.length === 0 ? (
              <tr><td className="px-4 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={7}>{t("empty")}</td></tr>
            ) : clusters.map((cluster) => (
              editingId === cluster.id ? (
                <ClusterEditRow
                  cluster={cluster}
                  key={cluster.id}
                  onCancel={() => setEditingId(null)}
                  onNotice={onNotice}
                  onSaved={() => setEditingId(null)}
                />
              ) : (
                <ClusterRow
                  cluster={cluster}
                  key={cluster.id}
                  onEdit={() => setEditingId(cluster.id)}
                  onNotice={onNotice}
                />
              )
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function ClusterRow({
  cluster,
  onEdit,
  onNotice
}: {
  cluster: KubernetesClusterRow
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")

  return (
    <tr>
      <td className="px-4 py-3 font-medium text-gray-900 dark:text-gray-100">{cluster.label}</td>
      <td className="px-4 py-3 font-mono text-xs text-gray-700 dark:text-gray-300">{cluster.api_server_url}</td>
      <td className="px-4 py-3 text-gray-700 dark:text-gray-300">
        {cluster.credential_kind === "token"
          ? t("credential_kind_token")
          : cluster.credential_kind === "client_cert"
            ? t("credential_kind_client_cert")
            : t("credential_kind_none")}
      </td>
      <td className="px-4 py-3">
        <StatusBadge tone={cluster.agentic_access_enabled ? "success" : "neutral"}>
          {cluster.agentic_access_enabled ? t("agentic_enabled") : t("agentic_disabled")}
        </StatusBadge>
      </td>
      <td className="px-4 py-3">
        <StatusBadge tone={cluster.allow_writes ? "warning" : "neutral"}>
          {cluster.allow_writes ? t("allow_writes_enabled") : t("allow_writes_disabled")}
        </StatusBadge>
      </td>
      <td className="px-4 py-3">
        <StatusBadge tone={cluster.insecure_skip_tls_verify ? "warning" : "neutral"}>
          {cluster.insecure_skip_tls_verify ? t("insecure_enabled") : t("insecure_disabled")}
        </StatusBadge>
      </td>
      <td className="px-4 py-3">
        <ClusterActions cluster={cluster} onEdit={onEdit} onNotice={onNotice} />
      </td>
    </tr>
  )
}

function ClusterActions({
  cluster,
  onEdit,
  onNotice
}: {
  cluster: KubernetesClusterRow
  onEdit: () => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("k8s_cluster")
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
        <TestButton onTest={() => testKubernetesCluster(cluster.id)} />
        <button
          className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
          onClick={onEdit}
          type="button"
        >
          {t("edit_button")}
        </button>
        <button
          className="rounded border border-red-300 dark:border-red-900 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950 disabled:cursor-not-allowed disabled:opacity-50"
          disabled={destroy.isPending}
          onClick={() => {
            if (window.confirm(t("confirm_delete", { label: cluster.label }))) {
              onNotice(null)
              destroy.mutate()
            }
          }}
          type="button"
        >
          {destroy.isPending ? t("deleting") : t("delete_button")}
        </button>
      </div>
      {destroy.isError ? (
        <p className="mt-2 text-right text-xs text-red-700 dark:text-red-300" role="alert">
          {errorMessage(destroy.error, t("delete_error_fallback"))}
        </p>
      ) : null}
    </div>
  )
}

function ClusterEditRow({
  cluster,
  onCancel,
  onNotice,
  onSaved
}: {
  cluster: KubernetesClusterRow
  onCancel: () => void
  onNotice: (message: string | null) => void
  onSaved: () => void
}) {
  const { t } = useT("k8s_cluster")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<KubernetesClusterInput>({
    label: cluster.label,
    agentic_access_enabled: cluster.agentic_access_enabled,
    allow_writes: cluster.allow_writes,
    insecure_skip_tls_verify: cluster.insecure_skip_tls_verify,
    kubeconfig: ""
  })
  const update = useMutation({
    mutationFn: () => updateKubernetesCluster(cluster.id, values),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(t("updated_notice", { label: payload.kubernetes_cluster.label }))
      onSaved()
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <tr>
      <td className="px-4 py-4" colSpan={7}>
        <form className="space-y-3" onSubmit={submit}>
          <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("edit_heading")}</h3>
          <ClusterFieldsGrid
            idPrefix={`edit-cluster-${cluster.id}`}
            kubeconfigHint={t("field_kubeconfig_hint_edit")}
            onChange={setValues}
            values={values}
          />
          <div className="flex flex-wrap items-center gap-3">
            <button
              className="rounded bg-gray-900 dark:bg-gray-100 px-3 py-1.5 text-sm font-medium text-white dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-white disabled:cursor-not-allowed disabled:opacity-50"
              disabled={update.isPending}
              type="submit"
            >
              {update.isPending ? t("saving") : t("save_button")}
            </button>
            <button
              className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
              onClick={onCancel}
              type="button"
            >
              {t("cancel_button")}
            </button>
            <TestButton onTest={() => testKubernetesCluster(cluster.id, values.kubeconfig || undefined)} />
          </div>
          {update.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, t("update_error_fallback"))}</p> : null}
        </form>
      </td>
    </tr>
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
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-label`}>
        {t("field_label")}
        <input
          className={INPUT_CLASSES}
          id={`${idPrefix}-label`}
          onChange={(event) => set("label", event.target.value)}
          required
          type="text"
          value={values.label}
        />
      </label>
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${idPrefix}-kubeconfig`}>
        {t("field_kubeconfig")}
        <textarea
          className={TEXTAREA_CLASSES}
          id={`${idPrefix}-kubeconfig`}
          onChange={(event) => set("kubeconfig", event.target.value)}
          placeholder={t("field_kubeconfig_placeholder")}
          required={kubeconfigRequired}
          rows={6}
          value={values.kubeconfig ?? ""}
        />
        {kubeconfigHint ? <span className="mt-1 block text-xs normal-case text-gray-500 dark:text-gray-400">{kubeconfigHint}</span> : null}
      </label>
      <label className="flex items-start gap-2 text-sm normal-case text-gray-700 dark:text-gray-300" htmlFor={`${idPrefix}-agentic-access`}>
        <input
          checked={values.agentic_access_enabled}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          id={`${idPrefix}-agentic-access`}
          onChange={(event) => set("agentic_access_enabled", event.target.checked)}
          type="checkbox"
        />
        <span>
          {t("field_agentic_access")}
          <span className="block text-xs text-gray-500 dark:text-gray-400">{t("field_agentic_access_hint")}</span>
        </span>
      </label>
      <label className="flex items-start gap-2 text-sm normal-case text-gray-700 dark:text-gray-300" htmlFor={`${idPrefix}-allow-writes`}>
        <input
          checked={values.allow_writes}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          id={`${idPrefix}-allow-writes`}
          onChange={(event) => set("allow_writes", event.target.checked)}
          type="checkbox"
        />
        <span>
          {t("field_allow_writes")}
          <span className="block text-xs text-gray-500 dark:text-gray-400">{t("field_allow_writes_hint")}</span>
        </span>
      </label>
      <label className="flex items-start gap-2 text-sm normal-case text-gray-700 dark:text-gray-300" htmlFor={`${idPrefix}-insecure`}>
        <input
          checked={values.insecure_skip_tls_verify}
          className="mt-0.5 rounded border-gray-300 dark:border-gray-600"
          id={`${idPrefix}-insecure`}
          onChange={(event) => set("insecure_skip_tls_verify", event.target.checked)}
          type="checkbox"
        />
        <span>
          {t("field_insecure_skip_tls_verify")}
          <span className="block text-xs text-gray-500 dark:text-gray-400">{t("field_insecure_skip_tls_verify_hint")}</span>
        </span>
      </label>
    </div>
  )
}

function TestButton({ onTest }: { onTest: () => Promise<KubernetesClusterTestResult> }) {
  const { t } = useT("k8s_cluster")
  const test = useMutation({ mutationFn: onTest })

  return (
    <div className="flex flex-col items-start gap-1">
      <button
        className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:cursor-not-allowed disabled:opacity-50"
        disabled={test.isPending}
        onClick={() => test.mutate()}
        type="button"
      >
        {test.isPending ? t("testing") : t("test_button")}
      </button>
      {test.isSuccess ? (
        test.data.success ? (
          <p className="text-xs text-emerald-700 dark:text-emerald-300">{t("test_success")}</p>
        ) : (
          <p className="text-xs text-red-700 dark:text-red-300">{t("test_failure", { error: test.data.error || "" })}</p>
        )
      ) : null}
      {test.isError ? <p className="text-xs text-red-700 dark:text-red-300">{errorMessage(test.error, t("test_error_fallback"))}</p> : null}
    </div>
  )
}

function StatusBadge({ children, tone }: { children: ReactNode; tone: "success" | "neutral" | "warning" }) {
  const classes = tone === "success"
    ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "warning"
      ? "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
      : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${classes}`}>{children}</span>
}

function Panel({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "error" | "success" }) {
  const classes = tone === "error"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
    : tone === "success"
      ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-gray-200 bg-white text-gray-700 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-200"
  return <div className={`rounded border px-4 py-3 text-sm ${classes}`}>{children}</div>
}

export default KubernetesClusters
