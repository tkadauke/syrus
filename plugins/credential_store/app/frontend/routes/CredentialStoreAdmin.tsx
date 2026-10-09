import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState, type FormEvent, type ReactNode } from "react"
import { useLocation } from "react-router-dom"
import { Button, DataTable, Input, Modal, Notice, Page, Select, Text, Textarea, TonePill, Toolbar, type DataTableSortDirection } from "@app/components/ui"
import { FilterBar, filterTreeFromPayload, topFilterChildren, type FilterChip, type FilterNode, type FilterSchemaField, type FilterTree } from "@app/components/FilterBar"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  visibleColumns,
  type DataTableColumnDef
} from "@app/components/dataTable"
import { errorMessage } from "@app/lib/errorMessage"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { useMediaQuery } from "@app/routes/dashboard/components"
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
const VISIBLE_COLUMNS_STORAGE_KEY = "syrus.credential_store.visible_columns"
const CREDENTIAL_MODAL_CLASS =
  "flex max-h-[calc(100dvh-2rem)] w-full max-w-4xl flex-col overflow-hidden rounded-[var(--radius-panel)] bg-surface shadow-[var(--shadow-panel)]"
const ROTATION_MODAL_CLASS = "w-full max-w-lg rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]"

type SortColumn =
  | "name"
  | "credential_type"
  | "scope_type"
  | "target"
  | "status"
  | "last_used_at"
  | "last_rotated_at"
  | "expires_at"
  | "allowed_surfaces"
  | "allowed_tools"
  | "safe_metadata"
  | "target_constraints"
  | "last_access_result"

type SortState = { column: SortColumn; direction: Exclude<DataTableSortDirection, "none"> }
type SortValue = boolean | number | string | null

const DEFAULT_SORT: SortState = { column: "name", direction: "ascending" }

const CREDENTIAL_SORT_ACCESSORS: Record<SortColumn, (credential: CredentialStoreCredential) => SortValue> = {
  name: (credential) => credential.name,
  credential_type: (credential) => credential.credential_type,
  scope_type: (credential) => credential.scope_type,
  target: (credential) => credential.scope_label || "",
  status: (credential) => credentialStatus(credential),
  last_used_at: (credential) => credential.last_access?.created_at || null,
  last_rotated_at: (credential) => credential.last_rotated_at,
  expires_at: (credential) => credential.expires_at,
  allowed_surfaces: (credential) => credential.allowed_surfaces.join(" "),
  allowed_tools: (credential) => credential.allowed_tools.join(" "),
  safe_metadata: (credential) => JSON.stringify(credential.safe_metadata || {}),
  target_constraints: (credential) => JSON.stringify(credential.target_constraints || {}),
  last_access_result: (credential) => credential.last_access?.result || null
}

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
  const location = useLocation()
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
          <Page.Title>{t("heading")}</Page.Title>
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
            pathname={location.pathname}
            payload={query.data}
            search={location.search}
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
            <Textarea
              aria-label={t("safe_metadata")}
              value={draft.safe_metadata}
              onChange={(event) => onChange({ ...draft, safe_metadata: event.target.value })}
            />
            <Text muted variant="caption">{t("safe_metadata_hint", { keys: payload.options.safe_metadata_keys.join(", ") })}</Text>
            {validationErrors.safe_metadata ? <FieldError>{validationErrors.safe_metadata}</FieldError> : null}
          </Field>
          <Field label={t("target_constraints")}>
            <Textarea
              aria-label={t("target_constraints")}
              value={draft.target_constraints}
              onChange={(event) => onChange({ ...draft, target_constraints: event.target.value })}
            />
            <Text muted variant="caption">{t("target_constraints_hint", { keys: payload.options.target_constraint_keys.join(", ") })}</Text>
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
  pathname,
  payload,
  search
}: {
  isRevoking: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (credential: CredentialStoreCredential) => void
  pathname: string
  payload: CredentialStorePayload
  search: string
}) {
  const { t } = useT("credential_store")
  const isMobile = useMediaQuery("(max-width: 767px)", false)
  const [sortState, setSortState] = useState<SortState>(DEFAULT_SORT)
  const filterTree = useMemo(() => filterTreeFromSearch(search), [search])
  const filterSchema = useMemo(() => credentialFilterSchema(payload, t), [payload, t])
  const columns = useMemo(
    () => buildCredentialColumns({ isRevoking, onEdit, onRevoke, onRotate, t }),
    [isRevoking, onEdit, onRevoke, onRotate, t]
  )
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: VISIBLE_COLUMNS_STORAGE_KEY })
  const filteredCredentials = useMemo(
    () => sortedCredentials(payload.credentials.filter((credential) => credentialMatchesFilter(credential, filterTree)), sortState),
    [filterTree, payload.credentials, sortState]
  )
  const emptyMessage = payload.credentials.length === 0 ? t("empty") : t("no_matches")

  function toggleSortColumn(column: SortColumn) {
    setSortState((current) => current.column === column ? {
      column,
      direction: current.direction === "ascending" ? "descending" : "ascending"
    } : { column, direction: "ascending" })
  }

  return (
    <div className="min-w-0 space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <FilterBar className="min-w-0 flex-1 space-y-2" filter={filterTree} filterSchema={filterSchema} pathname={pathname} search={search} />
        {!isMobile ? (
          <DataTableColumnMenu
            columns={columns}
            downLabel={t("column_down")}
            menuId="credential-store-columns-menu"
            moveDownLabel={(title) => t("column_move_down", { title })}
            moveUpLabel={(title) => t("column_move_up", { title })}
            onChange={preferences.onChange}
            order={preferences.order}
            triggerAriaLabel={t("columns")}
            triggerClassName="h-[var(--control-height-md)] w-[var(--control-height-md)]"
            triggerSize="icon"
            upLabel={t("column_up")}
            visibleLabel={t("visible_columns")}
          />
        ) : null}
      </div>

      {isMobile ? (
        <CredentialMobileList
          credentials={filteredCredentials}
          emptyMessage={emptyMessage}
          isRevoking={isRevoking}
          onEdit={onEdit}
          onRevoke={onRevoke}
          onRotate={onRotate}
        />
      ) : (
        <CredentialDataTable
          columns={columns}
          credentials={filteredCredentials}
          emptyMessage={emptyMessage}
          order={preferences.order}
          sortState={sortState}
          onReorder={preferences.onChange}
          onSort={toggleSortColumn}
        />
      )}
    </div>
  )
}

function CredentialDataTable({
  columns,
  credentials,
  emptyMessage,
  onReorder,
  onSort,
  order,
  sortState
}: {
  columns: DataTableColumnDef<CredentialStoreCredential>[]
  credentials: CredentialStoreCredential[]
  emptyMessage: string
  onReorder: (nextOrder: string[]) => void
  onSort: (column: SortColumn) => void
  order: string[] | null | undefined
  sortState: SortState
}) {
  const colSpan = visibleColumns({ columns, order }).length

  return (
    <DataTable.Root wrapperClassName="max-w-full">
      <DataTable.Header>
        <DataTableColumnHeaderRow
          columns={columns}
          onReorder={onReorder}
          onSort={(key) => onSort(key as SortColumn)}
          order={order}
          sortColumn={sortState.column}
          sortDirection={sortState.direction}
        />
      </DataTable.Header>
      <DataTable.Body>
        {credentials.length === 0 ? (
          <DataTable.Empty colSpan={colSpan}>{emptyMessage}</DataTable.Empty>
        ) : (
          credentials.map((credential) => (
            <DataTable.Row key={credential.id}>
              <DataTableColumnCells columns={columns} order={order} row={credential} />
            </DataTable.Row>
          ))
        )}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function CredentialMobileList({
  credentials,
  emptyMessage,
  isRevoking,
  onEdit,
  onRevoke,
  onRotate
}: {
  credentials: CredentialStoreCredential[]
  emptyMessage: string
  isRevoking: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (credential: CredentialStoreCredential) => void
}) {
  const { t } = useT("credential_store")

  if (credentials.length === 0) {
    return <div className="rounded border border-border bg-surface px-4 py-8 text-center text-[length:var(--text-body)] text-text-muted">{emptyMessage}</div>
  }

  return (
    <div className="divide-y divide-border rounded border border-border bg-surface">
      {credentials.map((credential) => (
        <div className="space-y-3 px-4 py-3" key={credential.id}>
          <div className="flex min-w-0 items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="flex min-w-0 items-center gap-2">
                <Text className="truncate font-medium" as="p">{credential.name}</Text>
                <CredentialStatusPill credential={credential} />
              </div>
              <Text muted variant="caption">
                {credential.credential_type} · {credential.scope_type} · {credential.scope_label || t("unknown_scope")}
              </Text>
            </div>
            <CredentialManagementButtons credential={credential} isRevoking={isRevoking} onEdit={onEdit} onRevoke={onRevoke} onRotate={onRotate} />
          </div>
          <div className="grid gap-1 text-[length:var(--text-caption)] text-text-muted">
            <span>{t("last_used")}: {formatDate(credential.last_access?.created_at || null, t("never"))}</span>
            <span>{t("last_rotated")}: {formatDate(credential.last_rotated_at, t("never"))}</span>
            <span>{t("expires")}: {formatDate(credential.expires_at, t("never"))}</span>
          </div>
        </div>
      ))}
    </div>
  )
}

function buildCredentialColumns({
  isRevoking,
  onEdit,
  onRevoke,
  onRotate,
  t
}: {
  isRevoking: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (credential: CredentialStoreCredential) => void
  t: (key: string, options?: Record<string, unknown>) => string
}): DataTableColumnDef<CredentialStoreCredential>[] {
  return [
    {
      key: "name",
      label: t("name"),
      required: true,
      sortKey: "name",
      cellClassName: "min-w-48",
      renderCell: (credential) => (
        <div className="min-w-0">
          <Text className="truncate font-medium" as="p">{credential.name}</Text>
          {credential.description ? <Text className="max-w-64 truncate" muted variant="caption">{credential.description}</Text> : null}
        </div>
      )
    },
    {
      key: "type",
      label: t("credential_type"),
      sortKey: "credential_type",
      cellClassName: "font-mono text-xs text-text-secondary",
      renderCell: (credential) => credential.credential_type
    },
    {
      key: "scope",
      label: t("scope_type"),
      sortKey: "scope_type",
      renderCell: (credential) => credential.scope_type
    },
    {
      key: "target",
      label: t("target"),
      sortKey: "target",
      renderCell: (credential) => credential.scope_label || t("unknown_scope")
    },
    {
      key: "status",
      label: t("status"),
      sortKey: "status",
      renderCell: (credential) => <CredentialStatusPill credential={credential} />
    },
    {
      key: "last_used",
      label: t("last_used"),
      sortKey: "last_used_at",
      renderCell: (credential) => formatDate(credential.last_access?.created_at || null, t("never"))
    },
    {
      key: "last_rotated",
      label: t("last_rotated"),
      sortKey: "last_rotated_at",
      renderCell: (credential) => formatDate(credential.last_rotated_at, t("never"))
    },
    {
      key: "expires",
      label: t("expires"),
      sortKey: "expires_at",
      renderCell: (credential) => formatDate(credential.expires_at, t("never"))
    },
    {
      key: "allowed_surfaces",
      label: t("allowed_surfaces"),
      defaultVisible: false,
      sortKey: "allowed_surfaces",
      renderCell: (credential) => credential.allowed_surfaces.join(", ") || "-"
    },
    {
      key: "allowed_tools",
      label: t("allowed_tools"),
      defaultVisible: false,
      sortKey: "allowed_tools",
      renderCell: (credential) => credential.allowed_tools.join(", ") || "-"
    },
    {
      key: "safe_metadata",
      label: t("safe_metadata"),
      defaultVisible: false,
      sortKey: "safe_metadata",
      cellClassName: "max-w-64",
      renderCell: (credential) => <InlineJson value={credential.safe_metadata} />
    },
    {
      key: "target_constraints",
      label: t("target_constraints"),
      defaultVisible: false,
      sortKey: "target_constraints",
      cellClassName: "max-w-64",
      renderCell: (credential) => <InlineJson value={credential.target_constraints} />
    },
    {
      key: "last_access_result",
      label: t("last_access_result"),
      defaultVisible: false,
      sortKey: "last_access_result",
      renderCell: (credential) => credential.last_access ? t("last_access_detail", {
        action: credential.last_access.action,
        surface: credential.last_access.surface,
        result: credential.last_access.result
      }) : t("never")
    },
    {
      key: "actions",
      label: t("actions"),
      required: true,
      pin: "end",
      align: "right",
      renderHeader: () => <span className="sr-only">{t("actions")}</span>,
      cellClassName: "min-w-72",
      renderCell: (credential) => (
        <CredentialManagementButtons credential={credential} isRevoking={isRevoking} onEdit={onEdit} onRevoke={onRevoke} onRotate={onRotate} />
      )
    }
  ]
}

function CredentialManagementButtons({
  credential,
  isRevoking,
  onEdit,
  onRevoke,
  onRotate
}: {
  credential: CredentialStoreCredential
  isRevoking: number | null
  onEdit: (credential: CredentialStoreCredential) => void
  onRevoke: (id: number) => void
  onRotate: (credential: CredentialStoreCredential) => void
}) {
  const { t } = useT("credential_store")
  return (
    <Toolbar className="justify-end">
      <Button disabled={!credential.can_manage} onClick={() => onEdit(credential)} size="sm" variant="secondary">{t("edit")}</Button>
      <Button disabled={!credential.can_manage || Boolean(credential.revoked_at)} onClick={() => onRotate(credential)} size="sm" variant="secondary">{t("rotate")}</Button>
      <Button disabled={!credential.can_manage || Boolean(credential.revoked_at) || isRevoking === credential.id} onClick={() => onRevoke(credential.id)} size="sm" variant="danger">
        {t("revoke")}
      </Button>
    </Toolbar>
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

function CredentialStatusPill({ credential }: { credential: CredentialStoreCredential }) {
  const { t } = useT("credential_store")
  return (
    <TonePill tone={credential.revoked_at ? "red" : credential.active ? "green" : "amber"}>
      {credential.revoked_at ? t("revoked") : credential.active ? t("active") : t("inactive")}
    </TonePill>
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

function InlineJson({ value }: { value: Record<string, unknown> }) {
  const rendered = useMemo(() => JSON.stringify(value || {}, null, 2), [value])
  return <pre className="max-h-32 overflow-auto whitespace-pre-wrap break-words text-xs text-text-secondary">{rendered}</pre>
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

function credentialFilterSchema(payload: CredentialStorePayload, t: (key: string, options?: Record<string, unknown>) => string): FilterSchemaField[] {
  return [
    {
      field: "text",
      label: t("filter_text"),
      bucket: "string",
      operators: ["contains"]
    },
    {
      field: "credential_type",
      label: t("credential_type"),
      bucket: "string",
      operators: ["is", "is_one_of"],
      values: payload.options.credential_types.map((type) => ({ value: type.name, label: type.label }))
    },
    {
      field: "scope_type",
      label: t("scope_type"),
      bucket: "string",
      operators: ["is", "is_one_of"],
      values: payload.options.scopes.map((scope) => ({ value: scope.value, label: scope.label }))
    },
    {
      field: "status",
      label: t("status"),
      bucket: "string",
      operators: ["is", "is_one_of"],
      values: [
        { value: "active", label: t("active") },
        { value: "inactive", label: t("inactive") },
        { value: "revoked", label: t("revoked") }
      ]
    },
    {
      field: "target",
      label: t("target"),
      bucket: "string",
      operators: ["contains", "is_set", "is_unset"]
    },
    {
      field: "expires_state",
      label: t("expires"),
      bucket: "string",
      operators: ["is", "is_one_of"],
      values: [
        { value: "never", label: t("never") },
        { value: "expired", label: t("expired") },
        { value: "expiring", label: t("expiring") },
        { value: "scheduled", label: t("scheduled") }
      ]
    },
    {
      field: "last_access_result",
      label: t("last_access_result"),
      bucket: "string",
      operators: ["contains", "is", "is_set", "is_unset"]
    }
  ]
}

function filterTreeFromSearch(search: string): FilterTree {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return filterTreeFromPayload(null)

  try {
    const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")
    const decoded = decodeURIComponent(escape(window.atob(padded)))
    return filterTreeFromPayload(JSON.parse(decoded) as Record<string, unknown>)
  } catch {
    return filterTreeFromPayload(null)
  }
}

function credentialMatchesFilter(credential: CredentialStoreCredential, filterTree: FilterTree): boolean {
  return topFilterChildren(filterTree).every((node) => credentialMatchesFilterNode(credential, node))
}

function credentialMatchesFilterNode(credential: CredentialStoreCredential, node: FilterNode): boolean {
  if ("not" in node && node.not) return !credentialMatchesFilterNode(credential, node.not)
  if ("or" in node && Array.isArray(node.or)) return node.or.some((child) => credentialMatchesFilterNode(credential, child))
  if ("and" in node && Array.isArray(node.and)) return node.and.every((child) => credentialMatchesFilterNode(credential, child))
  if ("field" in node) return credentialMatchesChip(credential, node)
  return true
}

function credentialMatchesChip(credential: CredentialStoreCredential, chip: FilterChip): boolean {
  const value = credentialFilterValue(credential, chip.field)
  const expected = chip.value

  switch (chip.op) {
    case "is":
      return String(value ?? "") === String(expected ?? "")
    case "is_not":
      return String(value ?? "") !== String(expected ?? "")
    case "is_one_of":
      return Array.isArray(expected) && expected.map(String).includes(String(value ?? ""))
    case "is_none_of":
      return Array.isArray(expected) && !expected.map(String).includes(String(value ?? ""))
    case "is_set":
      return value !== null && value !== undefined && String(value).length > 0
    case "is_unset":
      return value === null || value === undefined || String(value).length === 0
    case "contains":
    default:
      return String(value ?? "").toLowerCase().includes(String(expected ?? "").toLowerCase())
  }
}

function credentialFilterValue(credential: CredentialStoreCredential, field: string): SortValue {
  if (field === "text") return [
    credential.name,
    credential.description,
    credential.credential_type,
    credential.scope_type,
    credential.scope_label,
    credentialStatus(credential),
    credential.allowed_surfaces.join(" "),
    credential.allowed_tools.join(" "),
    JSON.stringify(credential.safe_metadata || {}),
    JSON.stringify(credential.target_constraints || {}),
    credential.last_access?.result
  ].filter(Boolean).join(" ")
  if (field === "credential_type") return credential.credential_type
  if (field === "scope_type") return credential.scope_type
  if (field === "status") return credentialStatus(credential)
  if (field === "target") return credential.scope_label
  if (field === "expires_state") return credentialExpiresState(credential)
  if (field === "last_access_result") return credential.last_access?.result || null
  return null
}

function credentialStatus(credential: CredentialStoreCredential) {
  if (credential.revoked_at) return "revoked"
  return credential.active ? "active" : "inactive"
}

function credentialExpiresState(credential: CredentialStoreCredential) {
  if (!credential.expires_at) return "never"

  const expiresAt = new Date(credential.expires_at).getTime()
  if (!Number.isFinite(expiresAt)) return "scheduled"

  const now = Date.now()
  if (expiresAt <= now) return "expired"
  if (expiresAt <= now + 30 * 24 * 60 * 60 * 1000) return "expiring"
  return "scheduled"
}

function sortedCredentials(credentials: CredentialStoreCredential[], sortState: SortState) {
  const factor = sortState.direction === "ascending" ? 1 : -1
  const valueFor = CREDENTIAL_SORT_ACCESSORS[sortState.column]

  return [...credentials].sort((left, right) => {
    const compared = compareSortValues(valueFor(left), valueFor(right))
    if (compared !== 0) return compared * factor

    return left.name.localeCompare(right.name)
  })
}

function compareSortValues(left: SortValue, right: SortValue) {
  if (left == null && right == null) return 0
  if (left == null) return -1
  if (right == null) return 1
  if (typeof left === "number" && typeof right === "number") return left - right
  if (typeof left === "boolean" && typeof right === "boolean") return Number(left) - Number(right)

  return String(left).localeCompare(String(right))
}

export default CredentialStoreAdmin
