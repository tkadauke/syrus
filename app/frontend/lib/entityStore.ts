import { useSyncExternalStore } from "react"
import type { ChatMessageItem, ChatPayload, ChatRecord } from "../api/chats"
import type { JobDetailPayload, JobEpic, JobRecord, JobRepository, JobRun, JobStep, JobWorkflow } from "../api/jobs"

export type EntityKind = "repositories" | "epics" | "jobs" | "workflows" | "steps" | "runs" | "chat_sessions" | "chat_messages" | "notifications"
export type EntityCompleteness = "partial" | "summary" | "detail"
export type EntityRevision = number | string | null

export type EntityRecord<T extends Record<string, unknown> = Record<string, unknown>> = {
  id: string
  kind: EntityKind
  revision: EntityRevision
  completeness: EntityCompleteness
  fields: T
  knownFields: Set<string>
  sources: Set<string>
  fetchedAt: number
}

type StoreState = {
  version: number
  entities: Record<EntityKind, Record<string, EntityRecord>>
}

type EntityInput<T extends Record<string, unknown>> = {
  kind: EntityKind
  id: string | number
  fields: T
  completeness?: EntityCompleteness
  revision?: EntityRevision
  source?: string
}

const COMPLETENESS_RANK: Record<EntityCompleteness, number> = {
  partial: 0,
  summary: 1,
  detail: 2
}

const EMPTY_ENTITIES: StoreState["entities"] = {
  repositories: {},
  epics: {},
  jobs: {},
  workflows: {},
  steps: {},
  runs: {},
  chat_sessions: {},
  chat_messages: {},
  notifications: {}
}

let state: StoreState = {
  version: 0,
  entities: EMPTY_ENTITIES
}

const listeners = new Set<() => void>()

function emit() {
  state = { ...state, version: state.version + 1 }
  listeners.forEach((listener) => listener())
}

export function subscribeEntityStore(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function getEntityStoreSnapshot() {
  return state
}

export function resetEntityStoreForTest() {
  state = { version: 0, entities: emptyEntities() }
  emit()
}

export function upsertEntity<T extends Record<string, unknown>>(input: EntityInput<T>): EntityRecord<T> {
  const kind = input.kind
  const id = String(input.id)
  const current = state.entities[kind][id] as EntityRecord<T> | undefined
  const incomingRevision = input.revision ?? revisionFromFields(input.fields)

  if (current && compareRevision(incomingRevision, current.revision) < 0) return current

  const nextFields = mergeFields(current?.fields, input.fields)
  const next: EntityRecord<T> = {
    id,
    kind,
    revision: freshestRevision(current?.revision ?? null, incomingRevision),
    completeness: freshestCompleteness(current?.completeness ?? "partial", input.completeness ?? "partial"),
    fields: nextFields,
    knownFields: new Set([...Array.from(current?.knownFields ?? []), ...knownFieldNames(input.fields)]),
    sources: new Set([...Array.from(current?.sources ?? []), input.source ?? "unknown"]),
    fetchedAt: Date.now()
  }

  state = {
    ...state,
    entities: {
      ...state.entities,
      [kind]: {
        ...state.entities[kind],
        [id]: next as EntityRecord
      }
    }
  }
  emit()
  return next
}

export function readEntity<T extends Record<string, unknown>>(kind: EntityKind, id: string | number): EntityRecord<T> | undefined {
  return state.entities[kind][String(id)] as EntityRecord<T> | undefined
}

export function entityHasFields(kind: EntityKind, id: string | number, fields: readonly string[], completeness?: EntityCompleteness) {
  const entity = readEntity(kind, id)
  if (!entity) return false
  if (completeness && COMPLETENESS_RANK[entity.completeness] < COMPLETENESS_RANK[completeness]) return false

  return fields.every((field) => entity.knownFields.has(field))
}

export function useEntitySelector<T extends Record<string, unknown>, Selected>(
  kind: EntityKind,
  id: string | number | null | undefined,
  selector: (entity: EntityRecord<T> | undefined) => Selected,
  equal: (left: Selected, right: Selected) => boolean = Object.is
) {
  let selected = selector(id == null ? undefined : readEntity<T>(kind, id))

  return useSyncExternalStore(
    subscribeEntityStore,
    () => {
      const next = selector(id == null ? undefined : readEntity<T>(kind, id))
      if (equal(selected, next)) return selected
      selected = next
      return next
    },
    () => selected
  )
}

export function normalizeJobDetailPayload(payload: JobDetailPayload, source = "job_detail") {
  const snapshot = payload as Partial<JobDetailPayload>
  if (snapshot.repository) upsertEntity({ kind: "repositories", id: snapshot.repository.id, fields: snapshot.repository as unknown as Record<string, unknown>, completeness: "detail", source })
  if (snapshot.epic) upsertEntity({ kind: "epics", id: snapshot.epic.id, fields: snapshot.epic as unknown as Record<string, unknown>, completeness: "summary", source })
  if (snapshot.origin_chat) upsertEntity({ kind: "chat_sessions", id: snapshot.origin_chat.chat_session_id, fields: snapshot.origin_chat as unknown as Record<string, unknown>, completeness: "summary", source })
  if (snapshot.job) normalizeJobRecord(snapshot.job, { completeness: "detail", source, extraFields: { deployment_stages: snapshot.deployment_stages } })

  snapshot.workflows?.forEach((workflow) => normalizeWorkflow(workflow, source))
  snapshot.work_units?.forEach((workUnit) => {
    if (workUnit.workflow) normalizeWorkflow(workUnit.workflow, source)
  })

  return payload
}

export function normalizeChatPayload(payload: ChatPayload, source = "chat_detail") {
  upsertEntity({ kind: "chat_sessions", id: payload.chat.id, fields: payload.chat as unknown as Record<string, unknown>, completeness: "detail", source })
  if (payload.chat.repository) {
    upsertEntity({ kind: "repositories", id: payload.chat.repository.id, fields: payload.chat.repository as unknown as Record<string, unknown>, completeness: "partial", source })
  }
  payload.recent_chats.forEach((chat) => upsertEntity({ kind: "chat_sessions", id: chat.id, fields: chat as unknown as Record<string, unknown>, completeness: "summary", source }))
  payload.messages.forEach((message) => normalizeChatMessage(message, source))
  if (payload.attached_coding_job) {
    normalizeJobRecord({
      id: payload.attached_coding_job.id,
      issue_title: payload.attached_coding_job.title,
      state: payload.attached_coding_job.state,
      branch_name: payload.attached_coding_job.branch_name,
      updated_at: null
    } as Partial<JobRecord> & { id: number }, { completeness: "partial", source, extraFields: { app_path: payload.attached_coding_job.app_path } })
  }
  payload.attachment_groups?.jobs.forEach((job) => {
    normalizeJobRecord({ id: job.id, issue_title: job.label, updated_at: null } as Partial<JobRecord> & { id: number }, { completeness: "partial", source })
  })

  return payload
}

export function normalizeJobRecord(record: JobRecord | (Partial<JobRecord> & { id: number }), options: { completeness?: EntityCompleteness; source?: string; extraFields?: Record<string, unknown> } = {}) {
  return upsertEntity({
    kind: "jobs",
    id: record.id,
    fields: { ...(record as unknown as Record<string, unknown>), ...(options.extraFields ?? {}) },
    completeness: options.completeness ?? "summary",
    source: options.source ?? "job_record"
  })
}

function normalizeWorkflow(workflow: JobWorkflow, source: string) {
  upsertEntity({ kind: "workflows", id: workflow.id, fields: workflow as unknown as Record<string, unknown>, completeness: "detail", source })
  workflow.steps.forEach((step) => normalizeStep(step, source))
}

function normalizeStep(step: JobStep, source: string) {
  upsertEntity({ kind: "steps", id: step.id, fields: step as unknown as Record<string, unknown>, completeness: "detail", source })
  step.runs.forEach((run) => normalizeRun(run, source))
}

function normalizeRun(run: JobRun, source: string) {
  upsertEntity({ kind: "runs", id: run.id, fields: run as unknown as Record<string, unknown>, completeness: "detail", source })
}

function normalizeChatMessage(message: ChatMessageItem, source: string) {
  upsertEntity({ kind: "chat_messages", id: message.id, fields: message as unknown as Record<string, unknown>, completeness: "detail", source })
  if (message.proposal?.materialized?.kind === "job") {
    normalizeJobRecord({
      id: message.proposal.materialized.job_id,
      issue_title: message.proposal.materialized.job_title,
      state: message.proposal.materialized.job_state ?? undefined,
      updated_at: null
    } as Partial<JobRecord> & { id: number }, { completeness: "partial", source })
  }
}

function mergeFields<T extends Record<string, unknown>>(current: T | undefined, incoming: T) {
  const next = { ...(current ?? {}) } as T
  Object.entries(incoming).forEach(([key, value]) => {
    if (value !== undefined) (next as Record<string, unknown>)[key] = value
  })
  return next
}

function knownFieldNames(fields: Record<string, unknown>) {
  return Object.entries(fields).flatMap(([key, value]) => value === undefined ? [] : [key])
}

function revisionFromFields(fields: Record<string, unknown>): EntityRevision {
  const explicit = fields.revision ?? fields.entity_revision ?? fields.lock_version
  if (typeof explicit === "number" || typeof explicit === "string") return explicit

  const updatedAt = fields.updated_at
  return typeof updatedAt === "string" ? updatedAt : null
}

function freshestCompleteness(current: EntityCompleteness, incoming: EntityCompleteness) {
  return COMPLETENESS_RANK[incoming] >= COMPLETENESS_RANK[current] ? incoming : current
}

function freshestRevision(current: EntityRevision, incoming: EntityRevision) {
  return compareRevision(incoming, current) >= 0 ? incoming : current
}

function compareRevision(left: EntityRevision, right: EntityRevision) {
  if (left == null && right == null) return 0
  if (left == null) return 0
  if (right == null) return 1

  const leftValue = revisionValue(left)
  const rightValue = revisionValue(right)
  if (leftValue > rightValue) return 1
  if (leftValue < rightValue) return -1
  return 0
}

function revisionValue(value: string | number) {
  if (typeof value === "number") return value

  const numeric = Number(value)
  if (Number.isFinite(numeric)) return numeric

  const timestamp = Date.parse(value)
  return Number.isNaN(timestamp) ? 0 : timestamp
}

function emptyEntities(): StoreState["entities"] {
  return {
    repositories: {},
    epics: {},
    jobs: {},
    workflows: {},
    steps: {},
    runs: {},
    chat_sessions: {},
    chat_messages: {},
    notifications: {}
  }
}

export type CanonicalJobEntity = EntityRecord<JobRecord & { deployment_stages?: JobDetailPayload["deployment_stages"] }>
export type CanonicalRepositoryEntity = EntityRecord<JobRepository>
export type CanonicalEpicEntity = EntityRecord<JobEpic>
export type CanonicalChatEntity = EntityRecord<ChatRecord>
