import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState, type FormEvent, type ReactNode } from "react"
import { Button, Input, Modal, Notice, Page, Section, Select, Text, Textarea, TonePill, Toolbar } from "@app/components/ui"
import { errorMessage } from "@app/lib/errorMessage"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import {
  createCredentialStoreCredential,
  fetchCredentialStore,
  rotateCredentialStoreCredential,
  updateCredentialStoreCredential,
  revokeCredentialStoreCredential,
  type CredentialStoreCredential,
  type CredentialStoreInput,
  type CredentialStorePayload
} from "../api/credentialStore"

const QUERY_KEY = ["credential_store", "credentials"]
const CREDENTIAL_MODAL_CLASS =
  "flex max-h-[calc(100dvh-2rem)] w-full max-w-4xl flex-col overflow-hidden rounded-[var(--radius-panel)] bg-surface shadow-[var(--shadow-panel)]"
const ROTATION_MODAL_CLASS = "w-full max-w-lg rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]"

type Draft = {
  id: number | null
  name: string
  description: string
  credential_type: string
  scope_type: CredentialStoreCredential["scope_type"]
  scope_id: string
  payload: string
  safe_metadata: string
  target_constraints: string
  allowed_surfaces: string
  allowed_tools: string
  expires_at: string
}

const EMPTY_DRAFT: Draft = {
  id: null,
  name: "",
  description: "",
  credential_type: "",
  scope_type: "user",
  scope_id: "",
  payload: "",
  safe_metadata: "{}",
  target_constraints: "{}",
  allowed_surfaces: "",
  allowed_tools: "",
  expires_at: ""
}

type CredentialModalState = { mode: "create" } | { mode: "edit"; credential: CredentialStoreCredential }
type RotationModalState = { credential: CredentialStoreCredential }
type JsonField = "safe_metadata" | "target_constraints"
type ValidationErrors = Partial<Record<JsonField, string>>

export function CredentialStoreAdmin() {
  const { t } = useT("credential_store")
  usePageTitle(t("page_title"))
  const queryClient = useQueryClient()
  const [credentialModal, setCredentialModal] = useState<CredentialModalState | null>(null)
  const [rotationModal, setRotationModal] = useState<RotationModalState | null>(null)

  const query = useQuery({
    queryKey: QUERY_KEY,
    queryFn: fetchCredentialStore
  })

  const saveCredential = useMutation({
    mutationFn: ({ id, input }: { id: number | null; input: CredentialStoreInput }) =>
      id ? updateCredentialStoreCredential(id, input) : createCredentialStoreCredential(input),
    onSuccess: (payload) => {
      queryClient.setQueryData(QUERY_KEY, payload)
      setCredentialModal(null)
    }
  })

  const rotateCredential = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: string }) => rotateCredentialStoreCredential(id, payload),
    onSuccess: (payload) => {
      queryClient.setQueryData(QUERY_KEY, payload)
      setRotationModal(null)
    }
  })

  const revokeCredential = useMutation({
    mutationFn: revokeCredentialStoreCredential,
    onSuccess: (payload) => queryClient.setQueryData(QUERY_KEY, payload)
  })

  function openCredentialModal(modal: CredentialModalState) {
    saveCredential.reset()
    setCredentialModal(modal)
  }

  function closeCredentialModal() {
    saveCredential.reset()
    setCredentialModal(null)
  }

  function openRotationModal(modal: RotationModalState) {
    rotateCredential.reset()
    setRotationModal(modal)
  }

  function closeRotationModal() {
    rotateCredential.reset()
    setRotationModal(null)
  }

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      <Page.Header className="items-end border-b border-border pb-4">
        <Page.HeadingGroup>
          <Text as="p" muted variant="label">
            {t("admin:section_label")}
          </Text>
          <Page.Title className="mt-1">{t("heading")}</Page.Title>
          <Page.Description>{t("description")}</Page.Description>
        </Page.HeadingGroup>
        <Page.Actions>
          <Button onClick={() => openCredentialModal({ mode: "create" })} type="button" variant="primary">
            {t("new_credential")}
          </Button>
        </Page.Actions>
      </Page.Header>

      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{errorMessage(query.error, t("load_error"))}</Notice> : null}
      {revokeCredential.isError ? <Notice tone="danger">{errorMessage(revokeCredential.error, t("revoke_error"))}</Notice> : null}
      {query.data ? (
        <>
          <CredentialList
            isRevoking={revokeCredential.isPending ? revokeCredential.variables : null}
            payload={query.data}
            onEdit={(credential) => openCredentialModal({ mode: "edit", credential })}
            onRevoke={(id) => revokeCredential.mutate(id)}
            onRotate={(credential) => openRotationModal({ credential })}
          />
          {credentialModal ? (
            <CredentialFormModal
              key={credentialModal.mode === "edit" ? `edit-${credentialModal.credential.id}` : "create"}
              isSaving={saveCredential.isPending}
              modal={credentialModal}
              payload={query.data}
              saveError={saveCredential.error}
              onClose={closeCredentialModal}
              onSubmit={(id, input) => saveCredential.mutate({ id, input })}
            />
          ) : null}
          {rotationModal ? (
            <RotateCredentialModal
              credential={rotationModal.credential}
              error={rotateCredential.error}
              isRotating={rotateCredential.isPending}
              onClose={closeRotationModal}
              onRotate={(payload) => rotateCredential.mutate({ id: rotationModal.credential.id, payload })}
            />
          ) : null}
        </>
      ) : null}
    </Page.Root>
  )
}

function CredentialFormModal({
  isSaving,
  modal,
  onClose,
  onSubmit,
  payload,
  saveError
}: {
  isSaving: boolean
  modal: CredentialModalState
  onClose: () => void
  onSubmit: (id: number | null, input: CredentialStoreInput) => void
  payload: CredentialStorePayload
  saveError: Error | null
}) {
  const { t } = useT("credential_store")
  const [draft, setDraft] = useState<Draft>(() => (modal.mode === "edit" ? draftFromCredential(modal.credential) : EMPTY_DRAFT))
  const [validationErrors, setValidationErrors] = useState<ValidationErrors>({})
  const title = modal.mode === "edit" ? t("form_edit_title") : t("form_create_title")

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const result = inputFromDraft(draft, payload, t)
    setValidationErrors(result.errors)
    if (!result.input) return
    onSubmit(draft.id, result.input)
  }

  return (
    <Modal className={CREDENTIAL_MODAL_CLASS} label={title} onClose={onClose} open>
      <form className="flex min-h-0 flex-col" onSubmit={submit}>
        <div className="border-b border-border px-5 py-4">
          <h2 className="text-lg font-semibold text-text-primary">{title}</h2>
          <Text className="mt-1" muted>
            {t("form_description")}
          </Text>
        </div>
        <div className="min-h-0 overflow-y-auto px-5 py-4">
          <CredentialForm
            draft={draft}
            payload={payload}
            validationErrors={validationErrors}
            onChange={(nextDraft) => {
              setDraft(nextDraft)
              setValidationErrors({})
            }}
          />
          {saveError ? (
            <p className="mt-4 text-sm text-danger-text" role="alert">
              {errorMessage(saveError, t("save_error"))}
            </p>
          ) : null}
        </div>
        <Toolbar className="border-t border-border px-5 py-4">
          <Button disabled={isSaving} type="submit">
            {draft.id ? t("save_changes") : t("create")}
          </Button>
          <Button onClick={onClose} type="button" variant="secondary">
            {t("cancel")}
          </Button>
        </Toolbar>
      </form>
    </Modal>
  )
}

function CredentialForm({
  draft,
  onChange,
  payload,
  validationErrors
}: {
  draft: Draft
  onChange: (draft: Draft) => void
  payload: CredentialStorePayload
  validationErrors: ValidationErrors
}) {
  const { t } = useT("credential_store")
  const scopeOptions = optionsForScope(payload, draft.scope_type)
  const typeOptions = payload.options.credential_types
  const selectedType = typeOptions.find((type) => type.name === draft.credential_type)

  return (
    <div className="space-y-4">
      <Field label={t("name")}>
        <Input value={draft.name} onChange={(event) => onChange({ ...draft, name: event.target.value })} />
      </Field>
      <Field label={t("credential_type")}>
        <Select value={draft.credential_type} onChange={(event) => onChange({ ...draft, credential_type: event.target.value })}>
          <option value="">{t("choose_type")}</option>
          {typeOptions.map((type) => (
            <option key={type.name} value={type.name}>
              {type.label} ({type.name})
            </option>
          ))}
        </Select>
        {selectedType?.description ? (
          <Text muted variant="caption">
            {selectedType.description}
          </Text>
        ) : null}
      </Field>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t("scope_type")}>
          <Select value={draft.scope_type} onChange={(event) => onChange({ ...draft, scope_type: event.target.value as Draft["scope_type"], scope_id: "" })}>
            {payload.options.scopes.map((scope) => (
              <option key={scope.value} value={scope.value}>
                {scope.label}
              </option>
            ))}
          </Select>
        </Field>
        <Field label={t("scope_target")}>
          <Select disabled={draft.scope_type === "instance"} value={draft.scope_id} onChange={(event) => onChange({ ...draft, scope_id: event.target.value })}>
            <option value="">{draft.scope_type === "instance" ? t("scope_instance") : t("choose_scope")}</option>
            {scopeOptions.map((option) => (
              <option key={option.id} value={option.id}>
                {option.label}
              </option>
            ))}
          </Select>
        </Field>
      </div>
      <Field label={draft.id ? t("payload_optional") : t("payload")}>
        <Textarea
          aria-label={t("payload")}
          autoComplete="new-password"
          placeholder={draft.id ? t("payload_placeholder_update") : t("payload_placeholder")}
          value={draft.payload}
          onChange={(event) => onChange({ ...draft, payload: event.target.value })}
        />
      </Field>
      <Field label={t("description_label")}>
        <Textarea value={draft.description} onChange={(event) => onChange({ ...draft, description: event.target.value })} />
      </Field>
      <div className="grid gap-3 lg:grid-cols-2">
        <Field label={t("safe_metadata")}>
          <Textarea
            aria-label={t("safe_metadata")}
            value={draft.safe_metadata}
            onChange={(event) => onChange({ ...draft, safe_metadata: event.target.value })}
          />
          <Text muted variant="caption">
            {t("safe_metadata_hint", { keys: payload.options.safe_metadata_keys.join(", ") })}
          </Text>
          {validationErrors.safe_metadata ? <FieldError>{validationErrors.safe_metadata}</FieldError> : null}
        </Field>
        <Field label={t("target_constraints")}>
          <Textarea
            aria-label={t("target_constraints")}
            value={draft.target_constraints}
            onChange={(event) => onChange({ ...draft, target_constraints: event.target.value })}
          />
          <Text muted variant="caption">
            {t("target_constraints_hint", { keys: payload.options.target_constraint_keys.join(", ") })}
          </Text>
          {validationErrors.target_constraints ? <FieldError>{validationErrors.target_constraints}</FieldError> : null}
        </Field>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t("allowed_surfaces")}>
          <Input value={draft.allowed_surfaces} onChange={(event) => onChange({ ...draft, allowed_surfaces: event.target.value })} />
        </Field>
        <Field label={t("allowed_tools")}>
          <Input value={draft.allowed_tools} onChange={(event) => onChange({ ...draft, allowed_tools: event.target.value })} />
        </Field>
      </div>
      <Field label={t("expires_at")}>
        <Input type="datetime-local" value={draft.expires_at} onChange={(event) => onChange({ ...draft, expires_at: event.target.value })} />
      </Field>
    </div>
  )
}

function CredentialList({
  isRevoking,
  onEdit,
  onRevoke,
  onRotate,
  payload
}: {
  isRevoking: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (credential: CredentialStoreCredential) => void
  payload: CredentialStorePayload
}) {
  const { t } = useT("credential_store")

  if (payload.credentials.length === 0) {
    return <Notice>{t("empty")}</Notice>
  }

  return (
    <div className="space-y-4">
      {payload.credentials.map((credential) => (
        <Section.Root key={credential.id} className="min-w-0" tone={credential.revoked_at ? "danger" : "default"}>
          <Section.Header>
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <Section.Title className="truncate">{credential.name}</Section.Title>
                <TonePill tone={credential.revoked_at ? "red" : credential.active ? "green" : "amber"}>
                  {credential.revoked_at ? t("revoked") : credential.active ? t("active") : t("inactive")}
                </TonePill>
              </div>
              <Section.Description>
                {credential.credential_type} · {credential.scope_type} · {credential.scope_label || t("unknown_scope")}
              </Section.Description>
            </div>
            <Toolbar>
              <Button disabled={!credential.can_manage} onClick={() => onEdit(credential)} size="sm" variant="secondary">
                {t("edit")}
              </Button>
              <Button disabled={!credential.can_manage || Boolean(credential.revoked_at)} onClick={() => onRotate(credential)} size="sm" variant="secondary">
                {t("rotate")}
              </Button>
              <Button
                disabled={!credential.can_manage || Boolean(credential.revoked_at) || isRevoking === credential.id}
                onClick={() => onRevoke(credential.id)}
                size="sm"
                variant="danger"
              >
                {t("revoke")}
              </Button>
            </Toolbar>
          </Section.Header>
          <Section.Body className="space-y-4" padding="md">
            <div className="grid gap-3 md:grid-cols-2">
              <MetadataBlock title={t("safe_metadata")} value={credential.safe_metadata} />
              <MetadataBlock title={t("target_constraints")} value={credential.target_constraints} />
            </div>
            <div className="grid gap-3 text-xs text-text-secondary md:grid-cols-3">
              <p>
                {t("last_rotated")}: {formatDate(credential.last_rotated_at, t("never"))}
              </p>
              <p>
                {t("expires")}: {formatDate(credential.expires_at, t("never"))}
              </p>
              <p>
                {t("last_used")}: {formatDate(credential.last_access?.created_at || null, t("never"))}
              </p>
            </div>
            {credential.last_access ? (
              <Text muted variant="caption">
                {t("last_access_detail", {
                  action: credential.last_access.action,
                  surface: credential.last_access.surface,
                  result: credential.last_access.result
                })}
              </Text>
            ) : null}
          </Section.Body>
        </Section.Root>
      ))}
    </div>
  )
}

function RotateCredentialModal({
  credential,
  error,
  isRotating,
  onClose,
  onRotate
}: {
  credential: CredentialStoreCredential
  error: Error | null
  isRotating: boolean
  onClose: () => void
  onRotate: (payload: string) => void
}) {
  const { t } = useT("credential_store")
  const [payload, setPayload] = useState("")
  const title = t("rotate_title", { name: credential.name })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!payload.trim()) return
    onRotate(payload)
  }

  return (
    <Modal className={ROTATION_MODAL_CLASS} label={title} onClose={onClose} open>
      <form className="space-y-4" onSubmit={submit}>
        <div>
          <h2 className="text-lg font-semibold text-text-primary">{title}</h2>
          <Text className="mt-1" muted>
            {t("rotate_description")}
          </Text>
        </div>
        <Field label={t("rotate_payload_label", { name: credential.name })}>
          <Textarea
            aria-label={t("rotate_payload_label", { name: credential.name })}
            autoComplete="new-password"
            placeholder={t("rotate_placeholder")}
            value={payload}
            onChange={(event) => setPayload(event.target.value)}
          />
        </Field>
        {error ? (
          <p className="text-sm text-danger-text" role="alert">
            {errorMessage(error, t("rotate_error"))}
          </p>
        ) : null}
        <Toolbar>
          <Button disabled={isRotating || !payload.trim()} type="submit">
            {t("rotate")}
          </Button>
          <Button onClick={onClose} type="button" variant="secondary">
            {t("cancel")}
          </Button>
        </Toolbar>
      </form>
    </Modal>
  )
}

function Field({ children, label }: { children: ReactNode; label: string }) {
  return (
    <label className="block space-y-1.5">
      <span className="text-sm font-medium text-text-primary">{label}</span>
      {children}
    </label>
  )
}

function FieldError({ children }: { children: ReactNode }) {
  return (
    <p className="text-sm text-danger-text" role="alert">
      {children}
    </p>
  )
}

function MetadataBlock({ title, value }: { title: string; value: Record<string, unknown> }) {
  const rendered = useMemo(() => JSON.stringify(value || {}, null, 2), [value])
  return (
    <div className="rounded-[var(--radius-panel)] border border-border bg-surface-inset p-3">
      <Text className="mb-2" variant="label">
        {title}
      </Text>
      <pre className="max-h-40 overflow-auto whitespace-pre-wrap break-words text-xs text-text-secondary">{rendered}</pre>
    </div>
  )
}

function optionsForScope(payload: CredentialStorePayload, scope: CredentialStoreCredential["scope_type"]) {
  if (scope === "user") return payload.options.users
  if (scope === "repository") return payload.options.repositories
  if (scope === "team") return payload.options.teams
  return []
}

function draftFromCredential(credential: CredentialStoreCredential): Draft {
  return {
    id: credential.id,
    name: credential.name,
    description: credential.description || "",
    credential_type: credential.credential_type,
    scope_type: credential.scope_type,
    scope_id: credential.scope_id ? String(credential.scope_id) : "",
    payload: "",
    safe_metadata: JSON.stringify(credential.safe_metadata || {}, null, 2),
    target_constraints: JSON.stringify(credential.target_constraints || {}, null, 2),
    allowed_surfaces: credential.allowed_surfaces.join(", "),
    allowed_tools: credential.allowed_tools.join(", "),
    expires_at: credential.expires_at ? credential.expires_at.slice(0, 16) : ""
  }
}

function inputFromDraft(
  draft: Draft,
  payload: CredentialStorePayload,
  t: ReturnType<typeof useT>["t"]
): { input: CredentialStoreInput | null; errors: ValidationErrors } {
  const fallbackType = payload.options.credential_types[0]?.name || ""
  const safeMetadata = parseObject(draft.safe_metadata, t("safe_metadata"), t)
  const targetConstraints = parseObject(draft.target_constraints, t("target_constraints"), t)
  const errors: ValidationErrors = {}
  if (safeMetadata.error) errors.safe_metadata = safeMetadata.error
  if (targetConstraints.error) errors.target_constraints = targetConstraints.error
  if (Object.keys(errors).length > 0) return { input: null, errors }

  const input: CredentialStoreInput = {
    name: draft.name,
    description: draft.description,
    credential_type: draft.credential_type || fallbackType,
    scope_type: draft.scope_type,
    scope_id: draft.scope_type === "instance" ? null : Number(draft.scope_id || 0),
    safe_metadata: safeMetadata.value,
    target_constraints: targetConstraints.value,
    allowed_surfaces: splitList(draft.allowed_surfaces),
    allowed_tools: splitList(draft.allowed_tools),
    expires_at: draft.expires_at ? new Date(draft.expires_at).toISOString() : null
  }
  if (draft.payload.trim()) input.payload = draft.payload
  return { input, errors: {} }
}

function parseObject(value: string, label: string, t: ReturnType<typeof useT>["t"]): { value: Record<string, unknown>; error: string | null } {
  if (!value.trim()) return { value: {}, error: null }
  try {
    const parsed = JSON.parse(value) as unknown
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return { value: parsed as Record<string, unknown>, error: null }
    return { value: {}, error: t("json_object_error", { field: label }) }
  } catch {
    return { value: {}, error: t("json_parse_error", { field: label }) }
  }
}

function splitList(value: string) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
}

function formatDate(value: string | null, fallback: string) {
  if (!value) return fallback
  return new Date(value).toLocaleString()
}

export default CredentialStoreAdmin
