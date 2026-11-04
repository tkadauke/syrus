import { useState } from "react"
import { useMutation } from "@tanstack/react-query"
import { AdminEventPageShell, AdminEventPanelMessage } from "@app/components/AdminEventLogPanel"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { Button, Input, Select, Surface } from "@app/components/ui"
import {
  applyPermissionFactoryReset,
  permissionResetScopes,
  previewPermissionFactoryReset,
  type PermissionResetPreview,
  type PermissionResetScope
} from "../api/adminPermissionFactoryReset"

export function AdminPermissionModel() {
  const { t } = useT("syrus_dev")
  usePageTitle(t("page_title_permission_model"))
  const [scopeType, setScopeType] = useState<PermissionResetScope>("user")
  const [scopeId, setScopeId] = useState("")
  const [typedConfirmation, setTypedConfirmation] = useState("")
  const [preview, setPreview] = useState<PermissionResetPreview | null>(null)

  const previewMutation = useMutation({
    mutationFn: () => previewPermissionFactoryReset(scopeType, scopeId.trim()),
    onSuccess: (nextPreview) => {
      setPreview(nextPreview)
      setTypedConfirmation("")
    }
  })
  const applyMutation = useMutation({
    mutationFn: () => applyPermissionFactoryReset(preview!, typedConfirmation),
    onSuccess: () => setPreview(null)
  })

  function changeScope(next: PermissionResetScope) {
    setScopeType(next)
    setPreview(null)
    setTypedConfirmation("")
  }

  const requiresId = scopeType !== "instance"
  const confirmationReady = !preview?.instance_confirmation || typedConfirmation === preview.instance_confirmation

  return (
    <AdminEventPageShell
      ariaLabel={t("permission_model.aria")}
      description={t("permission_model.description")}
      eyebrow={t("section_label")}
      title={t("permission_model.heading")}
    >
      <Surface aria-labelledby="permission-reset-scope" role="region">
        <h2 className="text-base font-semibold text-text-primary" id="permission-reset-scope">
          {t("permission_model.scope_heading")}
        </h2>
        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <label className="text-sm font-medium text-text-secondary">
            {t("permission_model.scope_label")}
            <Select className="mt-1" value={scopeType} onChange={(event) => changeScope(event.target.value as PermissionResetScope)}>
              {permissionResetScopes.map((scope) => (
                <option key={scope} value={scope}>
                  {t(`permission_model.scope_${scope}`)}
                </option>
              ))}
            </Select>
          </label>
          {requiresId ? (
            <label className="text-sm font-medium text-text-secondary">
              {t("permission_model.scope_id")}
              <Input
                className="mt-1"
                value={scopeId}
                onChange={(event) => {
                  setScopeId(event.target.value)
                  setPreview(null)
                }}
              />
            </label>
          ) : null}
        </div>
        <Button
          className="mt-4"
          variant="secondary"
          disabled={(requiresId && !scopeId.trim()) || previewMutation.isPending}
          onClick={() => previewMutation.mutate()}
        >
          {previewMutation.isPending ? t("permission_model.previewing") : t("permission_model.preview")}
        </Button>
        {previewMutation.isError ? (
          <div className="mt-4">
            <AdminEventPanelMessage tone="error">{errorMessage(previewMutation.error, t("permission_model.preview_error"))}</AdminEventPanelMessage>
          </div>
        ) : null}
      </Surface>

      {preview ? (
        <Surface aria-labelledby="permission-reset-preview" role="region" variant="warning">
          <h2 className="text-base font-semibold" id="permission-reset-preview">
            {t("permission_model.preview_heading")}
          </h2>
          <p className="mt-1 text-sm text-text-secondary">{t("permission_model.version", { version: preview.default_version })}</p>
          <dl className="mt-4 grid gap-2 sm:grid-cols-2" aria-label={t("permission_model.counts_aria")}>
            {Object.entries(preview.counts).map(([key, count]) => (
              <Surface className="flex justify-between gap-4" key={key} padding="sm" variant="panel">
                <dt className="text-sm text-text-secondary">{t(`permission_model.count_${key}`)}</dt>
                <dd className="font-mono text-sm font-semibold text-text-primary">{count}</dd>
              </Surface>
            ))}
          </dl>
          <h3 className="mt-5 text-sm font-semibold">{t("permission_model.retained_heading")}</h3>
          <ul className="mt-2 list-disc pl-5 text-sm text-text-secondary">
            {preview.retained_data.map((item) => (
              <li key={item}>{t(`permission_model.retained_${item}`)}</li>
            ))}
          </ul>
          {preview.instance_confirmation ? (
            <label className="mt-5 block max-w-lg text-sm font-medium text-danger-text">
              {t("permission_model.type_confirmation", { phrase: preview.instance_confirmation })}
              <Input autoComplete="off" className="mt-1" value={typedConfirmation} onChange={(event) => setTypedConfirmation(event.target.value)} />
            </label>
          ) : null}
          <Button className="mt-5" variant="danger" disabled={!confirmationReady || applyMutation.isPending} onClick={() => applyMutation.mutate()}>
            {applyMutation.isPending ? t("permission_model.applying") : t("permission_model.apply")}
          </Button>
          {applyMutation.isError ? (
            <div className="mt-4">
              <AdminEventPanelMessage tone="error">{errorMessage(applyMutation.error, t("permission_model.apply_error"))}</AdminEventPanelMessage>
            </div>
          ) : null}
        </Surface>
      ) : null}

      {applyMutation.isSuccess ? (
        <div role="status">
          <AdminEventPanelMessage>
            {t(applyMutation.data.changed ? "permission_model.completed" : "permission_model.completed_unchanged", { id: applyMutation.data.audit.id })}
          </AdminEventPanelMessage>
        </div>
      ) : null}
    </AdminEventPageShell>
  )
}

export default AdminPermissionModel
