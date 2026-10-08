import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState, type ReactNode } from "react"
import { Button, Input, Notice, Page, Section, Select, Text, Textarea, TonePill, Toolbar } from "@app/components/ui"
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

export function CredentialStoreAdmin() {
  const { t } = useT("credential_store")
  usePageTitle(t("page_title"))
  const queryClient = useQueryClient()
  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT)
  const [rotationPayloads, setRotationPayloads] = useState<Record<number, string>>({})

  const query = useQuery({
    queryKey: QUERY_KEY,
    queryFn: fetchCredentialStore
  })

  const saveCredential = useMutation({
    mutationFn: ({ id, input }: { id: number | null; input: CredentialStoreInput }) =>
      id ? updateCredentialStoreCredential(id, input) : createCredentialStoreCredential(input),
    onSuccess: (payload) => {
      queryClient.setQueryData(QUERY_KEY, payload)
      setDraft(EMPTY_DRAFT)
    }
  })

  const rotateCredential = useMutation({
    mutationFn: ({ id, payload }: { id: number; payload: string }) => rotateCredentialStoreCredential(id, payload),
    onSuccess: (payload, variables) => {
      queryClient.setQueryData(QUERY_KEY, payload)
      setRotationPayloads((values) => ({ ...values, [variables.id]: "" }))
    }
  })

  const revokeCredential = useMutation({
    mutationFn: revokeCredentialStoreCredential,
    onSuccess: (payload) => queryClient.setQueryData(QUERY_KEY, payload)
  })

  function editCredential(credential: CredentialStoreCredential) {
    setDraft({
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
    })
  }

  function submitDraft(payload: CredentialStorePayload) {
    saveCredential.mutate({ id: draft.id, input: inputFromDraft(draft, payload) })
  }

  return (
    <Page.Root aria-label={t("aria_page")} gutter="responsive" size="wide">
      <Page.Header className="items-end border-b border-border pb-4">
        <Page.HeadingGroup>
          <Page.Title>{t("heading")}</Page.Title>
          <Page.Description>{t("description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{errorMessage(query.error, t("load_error"))}</Notice> : null}
      {saveCredential.isError ? <Notice tone="danger">{errorMessage(saveCredential.error, t("save_error"))}</Notice> : null}
      {rotateCredential.isError ? <Notice tone="danger">{errorMessage(rotateCredential.error, t("rotate_error"))}</Notice> : null}
      {revokeCredential.isError ? <Notice tone="danger">{errorMessage(revokeCredential.error, t("revoke_error"))}</Notice> : null}
      {query.data ? (
        <div className="grid gap-6 xl:grid-cols-[minmax(22rem,0.85fr),minmax(0,1.4fr)]">
          <CredentialForm
            draft={draft}
            isSaving={saveCredential.isPending}
            payload={query.data}
            onCancel={() => setDraft(EMPTY_DRAFT)}
            onChange={setDraft}
            onSubmit={() => submitDraft(query.data)}
          />
          <CredentialList
            isRevoking={revokeCredential.isPending ? revokeCredential.variables : null}
            isRotating={rotateCredential.isPending ? rotateCredential.variables?.id ?? null : null}
            payload={query.data}
            rotationPayloads={rotationPayloads}
            onEdit={editCredential}
            onRevoke={(id) => revokeCredential.mutate(id)}
            onRotate={(id) => rotateCredential.mutate({ id, payload: rotationPayloads[id] || "" })}
            onRotationPayloadChange={(id, value) => setRotationPayloads((values) => ({ ...values, [id]: value }))}
          />
        </div>
      ) : null}
    </Page.Root>
  )
}

function CredentialForm({
  draft,
  isSaving,
  onCancel,
  onChange,
  onSubmit,
  payload
}: {
  draft: Draft
  isSaving: boolean
  onCancel: () => void
  onChange: (draft: Draft) => void
  onSubmit: () => void
  payload: CredentialStorePayload
}) {
  const { t } = useT("credential_store")
  const scopeOptions = optionsForScope(payload, draft.scope_type)
  const typeOptions = payload.options.credential_types
  const selectedType = typeOptions.find((type) => type.name === draft.credential_type)

  return (
    <Section.Root>
      <Section.Header>
        <div>
          <Section.Title>{draft.id ? t("form_edit_title") : t("form_create_title")}</Section.Title>
          <Section.Description>{t("form_description")}</Section.Description>
        </div>
      </Section.Header>
      <Section.Body className="space-y-4" padding="md">
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
          {selectedType?.description ? <Text muted variant="caption">{selectedType.description}</Text> : null}
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
            <Textarea value={draft.safe_metadata} onChange={(event) => onChange({ ...draft, safe_metadata: event.target.value })} />
            <Text muted variant="caption">{t("safe_metadata_hint", { keys: payload.options.safe_metadata_keys.join(", ") })}</Text>
          </Field>
          <Field label={t("target_constraints")}>
            <Textarea value={draft.target_constraints} onChange={(event) => onChange({ ...draft, target_constraints: event.target.value })} />
            <Text muted variant="caption">{t("target_constraints_hint", { keys: payload.options.target_constraint_keys.join(", ") })}</Text>
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
        <Toolbar>
          <Button disabled={isSaving} onClick={onSubmit}>{draft.id ? t("save_changes") : t("create")}</Button>
          {draft.id ? <Button onClick={onCancel} variant="secondary">{t("cancel")}</Button> : null}
        </Toolbar>
      </Section.Body>
    </Section.Root>
  )
}

function CredentialList({
  isRevoking,
  isRotating,
  onEdit,
  onRevoke,
  onRotate,
  onRotationPayloadChange,
  payload,
  rotationPayloads
}: {
  isRevoking: number | null
  isRotating: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (id: number) => void
  onRotationPayloadChange: (id: number, value: string) => void
  payload: CredentialStorePayload
  rotationPayloads: Record<number, string>
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
              <Button disabled={!credential.can_manage} onClick={() => onEdit(credential)} size="sm" variant="secondary">{t("edit")}</Button>
              <Button disabled={!credential.can_manage || Boolean(credential.revoked_at) || isRevoking === credential.id} onClick={() => onRevoke(credential.id)} size="sm" variant="danger">
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
              <p>{t("last_rotated")}: {formatDate(credential.last_rotated_at, t("never"))}</p>
              <p>{t("expires")}: {formatDate(credential.expires_at, t("never"))}</p>
              <p>{t("last_used")}: {formatDate(credential.last_access?.created_at || null, t("never"))}</p>
            </div>
            {credential.last_access ? (
              <Text muted variant="caption">
                {t("last_access_detail", { action: credential.last_access.action, surface: credential.last_access.surface, result: credential.last_access.result })}
              </Text>
            ) : null}
            <div className="flex flex-col gap-2 sm:flex-row">
              <Input
                aria-label={t("rotate_payload_label", { name: credential.name })}
                autoComplete="new-password"
                placeholder={t("rotate_placeholder")}
                type="password"
                value={rotationPayloads[credential.id] || ""}
                onChange={(event) => onRotationPayloadChange(credential.id, event.target.value)}
              />
              <Button
                disabled={!credential.can_manage || isRotating === credential.id || !(rotationPayloads[credential.id] || "").trim()}
                onClick={() => onRotate(credential.id)}
                variant="secondary"
              >
                {t("rotate")}
              </Button>
            </div>
          </Section.Body>
        </Section.Root>
      ))}
    </div>
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

function MetadataBlock({ title, value }: { title: string; value: Record<string, unknown> }) {
  const rendered = useMemo(() => JSON.stringify(value || {}, null, 2), [value])
  return (
    <div className="rounded-[var(--radius-panel)] border border-border bg-surface-inset p-3">
      <Text className="mb-2" variant="label">{title}</Text>
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

function inputFromDraft(draft: Draft, payload: CredentialStorePayload): CredentialStoreInput {
  const fallbackType = payload.options.credential_types[0]?.name || ""
  const input: CredentialStoreInput = {
    name: draft.name,
    description: draft.description,
    credential_type: draft.credential_type || fallbackType,
    scope_type: draft.scope_type,
    scope_id: draft.scope_type === "instance" ? null : Number(draft.scope_id || 0),
    safe_metadata: parseObject(draft.safe_metadata),
    target_constraints: parseObject(draft.target_constraints),
    allowed_surfaces: splitList(draft.allowed_surfaces),
    allowed_tools: splitList(draft.allowed_tools),
    expires_at: draft.expires_at ? new Date(draft.expires_at).toISOString() : null
  }
  if (draft.payload.trim()) input.payload = draft.payload
  return input
}

function parseObject(value: string) {
  if (!value.trim()) return {}
  const parsed = JSON.parse(value) as unknown
  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {}
}

function splitList(value: string) {
  return value.split(",").map((item) => item.trim()).filter(Boolean)
}

function formatDate(value: string | null, fallback: string) {
  if (!value) return fallback
  return new Date(value).toLocaleString()
}

export default CredentialStoreAdmin
