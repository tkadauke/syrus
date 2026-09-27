import { useQuery } from "@tanstack/react-query"
import { useCallback, useEffect, useState } from "react"
import { createPortal } from "react-dom"
import { PanelMessage } from "@app/components/PanelMessage"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import {
  fetchKubernetesConfigMapDetail,
  fetchKubernetesCronJobDetail,
  fetchKubernetesDaemonSetDetail,
  fetchKubernetesDeploymentDetail,
  fetchKubernetesIngressDetail,
  fetchKubernetesJobDetail,
  fetchKubernetesNamespaceDetail,
  fetchKubernetesNodeDetail,
  fetchKubernetesPersistentVolumeClaimDetail,
  fetchKubernetesPodDetail,
  fetchKubernetesSecretDetail,
  fetchKubernetesServiceDetail,
  fetchKubernetesStatefulSetDetail,
  type KubernetesResourceDetail
} from "../api/kubernetesResources"
import { toYaml } from "../lib/toYaml"

export type ResourceDetailKind =
  "pod" | "deployment" | "statefulset" | "daemonset" | "job" | "cronjob" | "service" | "ingress" | "configmap" | "secret" | "pvc" | "node" | "namespace"

export type ResourceDetailField = { label: string; value: string }

export type ResourceDetailSelection = {
  kind: ResourceDetailKind
  kindLabel: string
  name: string
  namespace: string | null
  fields: ResourceDetailField[]
}

type DetailFetcher = (clusterId: number, namespace: string, name: string) => Promise<KubernetesResourceDetail>

function namespaced(fetcher: (clusterId: number, namespace: string, name: string) => Promise<KubernetesResourceDetail>): DetailFetcher {
  return fetcher
}

function clusterScoped(fetcher: (clusterId: number, name: string) => Promise<KubernetesResourceDetail>): DetailFetcher {
  return (clusterId, _namespace, name) => fetcher(clusterId, name)
}

const DETAIL_FETCHERS: Record<ResourceDetailKind, DetailFetcher> = {
  pod: namespaced(fetchKubernetesPodDetail),
  deployment: namespaced(fetchKubernetesDeploymentDetail),
  statefulset: namespaced(fetchKubernetesStatefulSetDetail),
  daemonset: namespaced(fetchKubernetesDaemonSetDetail),
  job: namespaced(fetchKubernetesJobDetail),
  cronjob: namespaced(fetchKubernetesCronJobDetail),
  service: namespaced(fetchKubernetesServiceDetail),
  ingress: namespaced(fetchKubernetesIngressDetail),
  configmap: namespaced(fetchKubernetesConfigMapDetail),
  secret: namespaced(fetchKubernetesSecretDetail),
  pvc: namespaced(fetchKubernetesPersistentVolumeClaimDetail),
  node: clusterScoped(fetchKubernetesNodeDetail),
  namespace: clusterScoped(fetchKubernetesNamespaceDetail)
}

export function useResourceDetail() {
  const [selection, setSelection] = useState<ResourceDetailSelection | null>(null)
  const closeDetail = useCallback(() => setSelection(null), [])
  return { selection, openDetail: setSelection, closeDetail }
}

// One read-only drawer reused by every cluster-browser tab: key fields from
// the clicked row plus the full describe object as YAML. No editing, no
// apply -- the drawer never issues anything but the describe GET.
export function ResourceDetailDrawer({ clusterId, selection, onClose }: { clusterId: number; selection: ResourceDetailSelection | null; onClose: () => void }) {
  const { t } = useT("k8s_cluster")
  const detail = useQuery({
    queryKey: ["k8s_cluster", "describe", selection?.kind, clusterId, selection?.namespace, selection?.name],
    queryFn: () => DETAIL_FETCHERS[selection!.kind](clusterId, selection!.namespace ?? "", selection!.name),
    enabled: selection !== null
  })

  useEffect(() => {
    if (!selection) return
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [selection, onClose])

  if (!selection) return null

  const qualifiedName = selection.namespace ? `${selection.namespace}/${selection.name}` : selection.name

  return createPortal(
    <div className="fixed inset-0 z-50" role="presentation" onClick={onClose}>
      <aside
        aria-label={t("detail_title", { kind: selection.kindLabel, name: qualifiedName })}
        aria-modal="true"
        className="absolute inset-y-0 right-0 flex w-full max-w-2xl flex-col gap-4 overflow-y-auto border-l border-border bg-surface p-5"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-text-primary">{t("detail_title", { kind: selection.kindLabel, name: qualifiedName })}</h2>
            <p className="text-sm text-text-secondary">{t("detail_read_only_note")}</p>
          </div>
          <button
            className="shrink-0 rounded border border-border px-3 py-1.5 text-sm text-text-primary hover:bg-surface-raised"
            onClick={onClose}
            type="button"
          >
            {t("detail_close")}
          </button>
        </div>

        <dl className="grid grid-cols-2 gap-x-4 gap-y-2 rounded border border-border bg-surface-subtle p-4">
          {selection.fields.map((field) => (
            <div key={field.label}>
              <dt className="text-xs font-medium uppercase tracking-wide text-text-muted">{field.label}</dt>
              <dd className="break-words text-sm text-text-primary">{field.value}</dd>
            </div>
          ))}
        </dl>

        <section aria-label={t("detail_yaml_heading")}>
          <h3 className="mb-2 text-xs font-semibold uppercase text-text-muted">{t("detail_yaml_heading")}</h3>
          {detail.isPending ? <PanelMessage>{t("detail_loading")}</PanelMessage> : null}
          {detail.isError ? <PanelMessage tone="error">{errorMessage(detail.error, t("detail_error_loading"))}</PanelMessage> : null}
          {detail.isSuccess ? (
            <pre className="overflow-x-auto rounded border border-border bg-surface-subtle p-4 font-mono text-xs text-text-primary">
              {toYaml(detail.data.object)}
            </pre>
          ) : null}
        </section>
      </aside>
    </div>,
    document.body
  )
}

// Accessible name-cell opener: the row itself is clickable for pointer users,
// this button keeps the same action reachable by keyboard and screen readers.
export function DetailNameButton({ name, onOpen }: { name: string; onOpen: () => void }) {
  return (
    <button
      className="text-left font-medium hover:underline focus-visible:underline"
      onClick={(event) => {
        event.stopPropagation()
        onOpen()
      }}
      type="button"
    >
      {name}
    </button>
  )
}
