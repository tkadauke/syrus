import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { SectionHeading } from "@app/components/Heading"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import type { FormEvent } from "react"
import { useEffect, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "@app/api/client"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import {
  createMemory,
  deleteMemory,
  fetchMemories,
  fetchMemoryAuditEvents,
  publishMemory,
  unpublishMemory,
  updateMemory,
  type MemoriesPayload,
  type MemoryAuditEvent,
  type MemoryAuditEventActor,
  type MemoryKind,
  type MemoryRow,
  type MemoryScope
} from "../api/memories"
import { CloseIcon } from "@app/components/CloseIcon"
import { FilterBar } from "@app/components/FilterBar"
import { NoticeToast } from "@app/components/NoticeToast"
import { Select } from "@app/components/Select"
import { Markdown } from "@app/lib/Markdown"
import { useConfirm } from "@app/hooks/useConfirm"
import { Button, buttonClasses } from "@app/components/Button"
import { PILL_TONE_CLASSES, TonePill } from "@app/components/StatusPill"
import {
  DataTable,
  DataTableBody,
  DataTableCell,
  DataTableHead,
  DataTableHeader,
  FormActions,
  FormErrorText,
  FormField,
  FormLabel,
  Notice,
  Page,
  PageDescription,
  PageHeader,
  PageHeading,
  Section,
  TableSurface,
  Text
} from "@app/components/ui"

const kindKeys: Record<string, string> = {
  user_pref: "kind_user_pref",
  project_fact: "kind_project_fact",
  feedback: "kind_feedback",
  reference: "kind_reference",
  decision: "kind_decision"
}

const kindClasses: Record<string, string> = {
  user_pref: PILL_TONE_CLASSES.blue,
  project_fact: "bg-emerald-50 text-emerald-700 ring-emerald-200 dark:bg-emerald-950 dark:text-emerald-200 dark:ring-emerald-800",
  feedback: "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-950 dark:text-amber-200 dark:ring-amber-800",
  reference: "bg-slate-100 text-slate-700 ring-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:ring-slate-700",
  decision: "bg-fuchsia-50 text-fuchsia-700 ring-fuchsia-200 dark:bg-fuchsia-950 dark:text-fuchsia-200 dark:ring-fuchsia-800"
}

export function MemoriesRoute() {
  const { t } = useT("agent_memory")
  usePageTitle(t("heading"))
  const location = useLocation()
  const search = location.search || ""
  const [notice, setNotice] = useState<string | null>(null)
  const memories = useQuery({
    queryKey: ["memories", search],
    queryFn: () => fetchMemories(search)
  })

  return (
    <Page aria-label={t("aria_memories")} size="wide">
      <PageHeader>
        <PageHeading>{t('heading')}</PageHeading>
        <PageDescription className="max-w-2xl">{t('description')}</PageDescription>
      </PageHeader>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {memories.isPending ? <Notice>{t('loading')}</Notice> : null}
      {memories.isError ? <MemoriesError error={memories.error} /> : null}
      {memories.isSuccess ? <MemoriesView onNotice={setNotice} payload={memories.data} /> : null}
    </Page>
  )
}

function MemoriesView({ payload, onNotice }: { payload: MemoriesPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("agent_memory")
  const location = useLocation()
  const navigate = useNavigate()
  const [creating, setCreating] = useState(false)
  const showDeleted = payload.deleted

  function toggleDeletedView() {
    const params = new URLSearchParams(location.search)
    if (showDeleted) params.delete("deleted")
    else params.set("deleted", "true")
    params.delete("page")
    navigate({ pathname: location.pathname, search: params.toString() ? `?${params.toString()}` : "" })
  }

  return (
    <>
      <Section>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <FilterBar
            filter={payload.filter}
            filterSchema={payload.controls.filter_schema}
            legacyFilterKeys={["scope", "kind", "published", "search", "repository_id"]}
            pathname={location.pathname}
            search={location.search}
            suggestionSearch={{ surface: "memories", subject: "memory" }}
          />
          <div className="flex shrink-0 gap-2">
            <Button onClick={toggleDeletedView} variant="secondary">
              {showDeleted ? t('view_active') : t('view_deleted')}
            </Button>
            {showDeleted ? null : (
              <Button onClick={() => setCreating(true)} variant="primary">
                {t('create')}
              </Button>
            )}
          </div>
        </div>
      </Section>
      <MemoriesTable onNotice={onNotice} payload={payload} showDeleted={showDeleted} />
      <MemoryPagination pagination={payload.pagination} />
      {creating ? <MemoryModal mode="create" onClose={() => setCreating(false)} onNotice={onNotice} payload={payload} /> : null}
    </>
  )
}

function MemoriesTable({ payload, onNotice, showDeleted }: { payload: MemoriesPayload; onNotice: (message: string | null) => void; showDeleted: boolean }) {
  const { t } = useT("agent_memory")
  const showOwner = payload.current_user.admin
  const columnCount = showOwner ? 7 : 6

  return (
    <TableSurface>
      <DataTable>
        <DataTableHead>
          <tr>
            <DataTableHeader>{t('col_kind')}</DataTableHeader>
            <DataTableHeader>{t('col_scope')}</DataTableHeader>
            {showOwner ? <DataTableHeader>{t('col_owner')}</DataTableHeader> : null}
            <DataTableHeader>{t('col_content')}</DataTableHeader>
            <DataTableHeader>{showDeleted ? t('col_deleted') : t('col_published')}</DataTableHeader>
            <DataTableHeader>{t('col_created')}</DataTableHeader>
            <DataTableHeader><span className="sr-only">{t('col_actions')}</span></DataTableHeader>
          </tr>
        </DataTableHead>
        <DataTableBody>
          {payload.memories.length === 0 ? (
            <tr><DataTableCell className="py-6 text-center text-text-muted" colSpan={columnCount}>{showDeleted ? t('no_deleted_results') : t('no_results')}</DataTableCell></tr>
          ) : payload.memories.map((memory) => (
            <MemoryRowView key={memory.id} memory={memory} onNotice={onNotice} payload={payload} showDeleted={showDeleted} showOwner={showOwner} />
          ))}
        </DataTableBody>
      </DataTable>
    </TableSurface>
  )
}

function MemoryRowView({ memory, payload, showOwner, showDeleted, onNotice }: { memory: MemoryRow; payload: MemoriesPayload; showOwner: boolean; showDeleted: boolean; onNotice: (message: string | null) => void }) {
  const { t } = useT("agent_memory")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [viewing, setViewing] = useState(false)
  const [editing, setEditing] = useState(false)
  const [viewingHistory, setViewingHistory] = useState(false)
  const publish = useMutation({
    mutationFn: () => memory.published ? unpublishMemory(memory.paths.app_publish_path) : publishMemory(memory.paths.app_publish_path),
    onSuccess: (payload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(payload.message || (memory.published ? t('unpublished_notice') : t('published_notice')))
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteMemory(memory.paths.app_memory_path),
    onSuccess: (payload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(payload.message || t('deleted'))
    }
  })

  return (
    <tr className="align-top">
      <DataTableCell><KindBadge kind={memory.kind} /></DataTableCell>
      <DataTableCell className="text-text-secondary">{memory.scope === "global" ? t('scope_global') : memory.repository_name || `${t('scope_repository')} #${memory.scope_id}`}</DataTableCell>
      {showOwner ? <DataTableCell className="text-text-secondary">{memory.owner.name}</DataTableCell> : null}
      <DataTableCell className="max-w-2xl text-text-primary">
        <Markdown className="chat-prose line-clamp-2 text-sm text-text-primary break-words" text={memory.content} />
        <div className="mt-1 flex flex-wrap items-center gap-2">
          <button className="text-xs text-brand-emphasis underline hover:no-underline" onClick={() => setViewing(true)} type="button">
            {t('see_more')}
          </button>
          {memory.changed && memory.permissions.can_manage ? (
            <button className="contents" onClick={() => setViewingHistory(true)} type="button">
              <TonePill tone="amber">{t('changed_badge')}</TonePill>
            </button>
          ) : null}
        </div>
      </DataTableCell>
      <DataTableCell>
        {showDeleted ? (
          <Text as="span">
            {memory.deleted_by
              ? t('deleted_by', { name: memory.deleted_by.name })
              : t('deleted_by_unknown')}
            {memory.deleted_at ? <><br /><RelativeTimestamp value={memory.deleted_at} /></> : null}
          </Text>
        ) : (
          <TonePill tone={memory.published ? "green" : "gray"}>{memory.published ? t('published_label') : t('unpublished_label')}</TonePill>
        )}
      </DataTableCell>
      <DataTableCell className="text-text-secondary"><RelativeTimestamp value={memory.created_at} /></DataTableCell>
      <DataTableCell>
        <div className="flex justify-end gap-2">
          {memory.permissions.can_manage ? (
            <Button onClick={() => setViewingHistory(true)} size="sm" variant="secondary">
              {t('history')}
            </Button>
          ) : null}
          {!showDeleted && memory.permissions.can_manage ? (
            <Button onClick={() => setEditing(true)} size="sm" variant="secondary">
              {t('edit')}
            </Button>
          ) : null}
          {!showDeleted && memory.permissions.can_publish ? (
            <Button disabled={publish.isPending} onClick={() => publish.mutate()} size="sm" variant="secondary">
              {memory.published ? t('unpublish') : t('publish')}
            </Button>
          ) : null}
          {!showDeleted && memory.permissions.can_manage ? (
            <Button
              variant="danger"
              size="sm"
              disabled={destroy.isPending}
              onClick={async () => {
                if (await confirm({ message: t('confirm_delete'), destructive: true })) {
                  onNotice(null)
                  destroy.mutate()
                }
              }}
            >
              {destroy.isPending ? t('deleting') : t('delete')}
            </Button>
          ) : null}
        </div>
        {publish.isError ? <FormErrorText className="mt-2" role="alert">{errorMessage(publish.error, "Unable to change publish state.")}</FormErrorText> : null}
        {destroy.isError ? <FormErrorText className="mt-2" role="alert">{errorMessage(destroy.error, "Unable to delete memory.")}</FormErrorText> : null}
        {viewing ? <MemoryContentModal memory={memory} onClose={() => setViewing(false)} /> : null}
        {editing ? <MemoryModal memory={memory} mode="edit" onClose={() => setEditing(false)} onNotice={onNotice} payload={payload} /> : null}
        {viewingHistory ? <MemoryHistoryModal memory={memory} onClose={() => setViewingHistory(false)} /> : null}
        {dialog}
      </DataTableCell>
    </tr>
  )
}

function MemoryContentModal({ memory, onClose }: { memory: MemoryRow; onClose: () => void }) {
  const { t } = useT("agent_memory")
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby={`memory-content-modal-title-${memory.id}`}
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-4 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <SectionHeading id={`memory-content-modal-title-${memory.id}`}>{t('modal_content')}</SectionHeading>
            <button
              aria-label={t("common:close")}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>
          <Markdown className="chat-prose text-sm text-gray-800 break-words dark:text-gray-200" text={memory.content} />
        </div>
      </section>
    </div>
  )
}

function MemoryHistoryModal({ memory, onClose }: { memory: MemoryRow; onClose: () => void }) {
  const { t } = useT("agent_memory")
  const query = useQuery({
    queryKey: ["memory-audit-events", memory.paths.app_audit_events_path],
    queryFn: () => fetchMemoryAuditEvents(memory.paths.app_audit_events_path)
  })

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby={`memory-history-modal-title-${memory.id}`}
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-4 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <SectionHeading id={`memory-history-modal-title-${memory.id}`}>{t('history_title')}</SectionHeading>
            <button
              aria-label={t("common:close")}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>
          {query.isPending ? <Notice>{t('history_loading')}</Notice> : null}
          {query.isError ? <Notice tone="error" role="alert">{errorMessage(query.error, "Unable to load memory history.")}</Notice> : null}
          {query.isSuccess ? (
            <ol className="space-y-3">
              {query.data.audit_events.map((event) => <AuditEventRow key={event.id} event={event} />)}
            </ol>
          ) : null}
        </div>
      </section>
    </div>
  )
}

function AuditEventRow({ event }: { event: MemoryAuditEvent }) {
  const { t } = useT("agent_memory")

  return (
    <li className="rounded border border-border p-3">
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-text-muted">
        <span className="font-medium text-text-secondary">{eventTypeLabel(event.event_type, t)}</span>
        <span>{actorLabel(event.actor, t)}</span>
        <RelativeTimestamp value={event.created_at} />
      </div>
      {event.event_type === "updated" ? (
        <div className="mt-2 grid gap-3 sm:grid-cols-2">
          <AuditEventSnapshot label={t('history_previous')} snapshot={event.previous} />
          <AuditEventSnapshot label={t('history_new')} snapshot={event.new} />
        </div>
      ) : (
        <div className="mt-2">
          <AuditEventSnapshot label={null} snapshot={event.event_type === "created" ? event.new : event.previous} />
        </div>
      )}
    </li>
  )
}

function AuditEventSnapshot({ label, snapshot }: { label: string | null; snapshot: { content: string | null; kind: MemoryKind | null; confidence: number | null } }) {
  const { t } = useT("agent_memory")

  return (
    <div>
      {label ? <Text className="font-medium uppercase" size="xs" tone="muted">{label}</Text> : null}
      <Text className="mt-1 whitespace-pre-wrap" tone="secondary">{snapshot.content}</Text>
      <Text className="mt-1" size="xs" tone="muted">
        {snapshot.kind ? kindLabel(snapshot.kind, t) : null}
        {snapshot.confidence != null ? ` · ${t('history_confidence', { value: snapshot.confidence })}` : null}
      </Text>
    </div>
  )
}

function eventTypeLabel(eventType: MemoryAuditEvent["event_type"], t: (key: string) => string) {
  if (eventType === "created") return t('history_event_created')
  if (eventType === "updated") return t('history_event_updated')
  return t('history_event_deleted')
}

function actorLabel(actor: MemoryAuditEventActor, t: (key: string, options?: Record<string, unknown>) => string) {
  if (actor.kind === "user") return t('history_actor_user', { name: actor.name || "—" })
  if (actor.kind === "agent") return t('history_actor_agent')
  return t('history_actor_system')
}

function MemoryModal({ memory, mode, payload, onClose, onNotice }: { memory?: MemoryRow; mode: "create" | "edit"; payload: MemoriesPayload; onClose: () => void; onNotice: (message: string | null) => void }) {
  const { t } = useT("agent_memory")
  const queryClient = useQueryClient()
  const [kind, setKind] = useState<MemoryKind>(memory?.kind || payload.kinds[0] || "user_pref")
  const [scope, setScope] = useState<MemoryScope>(memory?.scope || "global")
  const [scopeId, setScopeId] = useState(memory?.scope_id ? String(memory.scope_id) : "")
  const [content, setContent] = useState(memory?.content || "")
  const title = mode === "create" ? t('title_create') : t('title_edit')
  const create = useMutation({
    mutationFn: () => createMemory({
      kind,
      scope,
      scope_id: scope === "repository" ? Number(scopeId) : null,
      content
    }),
    onSuccess: (nextPayload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(nextPayload.message || t('created'))
      onClose()
    }
  })
  const update = useMutation({
    mutationFn: () => updateMemory(memory?.paths.app_memory_path || "", {
      content,
      kind,
      scope,
      scope_id: scope === "repository" ? Number(scopeId) : null
    }),
    onSuccess: (nextPayload) => {
      queryClient.invalidateQueries({ queryKey: ["memories"] })
      onNotice(nextPayload.message || t('updated'))
      onClose()
    }
  })
  const pending = create.isPending || update.isPending
  const error = create.error || update.error

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  useEffect(() => {
    if (scope === "repository" && !scopeId && payload.repositories.length > 0) {
      setScopeId(String(payload.repositories[0].id))
    }
  }, [payload.repositories, scope, scopeId])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    if (mode === "create") create.mutate()
    else update.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="memory-modal-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-900"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <form className="space-y-5 p-5 sm:p-6" onSubmit={submit}>
          <div className="flex items-start justify-between gap-4">
            <SectionHeading id="memory-modal-title">{title}</SectionHeading>
            <button
              aria-label={t("common:close")}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-brand dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-300"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <FormField>
              <FormLabel htmlFor="memory-kind">{t('modal_kind')}</FormLabel>
              <Select className="mt-1" id="memory-kind" onChange={(event) => setKind(event.target.value as MemoryKind)} value={kind}>
                {payload.kinds.map((option) => <option key={option} value={option}>{kindLabel(option, t)}</option>)}
              </Select>
            </FormField>
            <FormField>
              <FormLabel htmlFor="memory-scope">{t('modal_scope')}</FormLabel>
              <Select className="mt-1" id="memory-scope" onChange={(event) => setScope(event.target.value as MemoryScope)} value={scope}>
                {payload.scopes.map((option) => <option key={option} value={option}>{option === "global" ? t('scope_global') : t('scope_repository')}</option>)}
              </Select>
            </FormField>
          </div>

          {scope === "repository" ? (
            <FormField>
              <FormLabel htmlFor="memory-repository">{t('modal_repository')}</FormLabel>
              <Select
                className="mt-1"
                disabled={payload.repositories.length === 0}
                id="memory-repository"
                onChange={(event) => setScopeId(event.target.value)}
                required
                value={scopeId}
              >
                {payload.repositories.length === 0 ? <option value="">{t('no_repositories')}</option> : null}
                {payload.repositories.map((repository) => <option key={repository.id} value={repository.id}>{repository.name}</option>)}
              </Select>
            </FormField>
          ) : null}

          <FormField>
            <FormLabel htmlFor="memory-content">{t('modal_content_label')}</FormLabel>
            <textarea
              id="memory-content"
              className="mt-1 block min-h-40 w-full rounded border border-border bg-surface px-2 py-1.5 text-sm text-text-primary disabled:bg-surface-raised disabled:text-text-muted"
              maxLength={2000}
              onChange={(event) => setContent(event.target.value)}
              required
              value={content}
            />
          </FormField>

          {error ? <FormErrorText role="alert">{errorMessage(error, mode === "create" ? "Unable to create memory." : "Unable to update memory.")}</FormErrorText> : null}

          <FormActions>
            <Button onClick={onClose} variant="secondary">
              {t('cancel')}
            </Button>
            <Button disabled={pending} type="submit" variant="primary">
              {pending ? t('saving') : t('save')}
            </Button>
          </FormActions>
        </form>
      </section>
    </div>
  )
}

function MemoryPagination({ pagination }: { pagination: MemoriesPayload["pagination"] }) {
  const { t } = useT("agent_memory")
  const location = useLocation()
  const navigate = useNavigate()
  if (pagination.total_pages <= 1) return null

  const firstItem = (pagination.page - 1) * pagination.per_page + 1
  const lastItem = Math.min(pagination.page * pagination.per_page, pagination.total)

  function go(page: number) {
    const params = new URLSearchParams(location.search)
    params.set("page", String(page))
    navigate({ pathname: location.pathname, search: `?${params.toString()}` })
  }

  return (
    <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
      <span>{t('showing', { first: firstItem, last: lastItem, total: pagination.total })}</span>
      <div className="flex gap-2">
        {pagination.page > 1 ? (
          <Button onClick={() => go(pagination.page - 1)} size="sm" variant="secondary">{t('previous')}</Button>
        ) : <span className={buttonClasses("secondary", "sm", "opacity-50")}>{t('previous')}</span>}
        {pagination.page < pagination.total_pages ? (
          <Button onClick={() => go(pagination.page + 1)} size="sm" variant="secondary">{t('next')}</Button>
        ) : <span className={buttonClasses("secondary", "sm", "opacity-50")}>{t('next')}</span>}
      </div>
    </div>
  )
}

function KindBadge({ kind }: { kind: string }) {
  const { t } = useT("agent_memory")
  return <span className={`inline-flex whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium ring-1 ${kindClasses[kind] || kindClasses.reference}`}>{kindLabel(kind, t)}</span>
}

function kindLabel(kind: string, t: (key: string) => string) {
  const key = kindKeys[kind]
  return key ? t(key) : kind
}

function MemoriesError({ error }: { error: unknown }) {
  const { t } = useT("agent_memory")
  return <Notice tone="error">{errorMessage(error, "Unable to load memories.")}</Notice>
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiError) return error.message
  if (error instanceof Error) return error.message
  return fallback
}

export default MemoriesRoute
