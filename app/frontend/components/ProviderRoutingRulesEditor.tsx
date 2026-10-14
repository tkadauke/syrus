import { useState } from "react"
import type { KeyboardEvent } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Button } from "./Button"
import { ChevronIcon } from "./ChevronIcon"
import { Modal } from "./Modal"
import { PanelMessage } from "./PanelMessage"
import { Select } from "./Select"
import { DataTable, Form, Pill, Surface } from "./ui"
import { errorMessage } from "../lib/errorMessage"
import { useT } from "../hooks/useT"
import {
  createProviderRoutingRule,
  deleteProviderRoutingRule,
  reorderProviderRoutingRules,
  updateProviderRoutingRule,
  type ProviderRoutingAction,
  type ProviderRoutingCandidate,
  type ProviderRoutingConditions,
  type ProviderRoutingInheritedContext,
  type ProviderRoutingOptions,
  type ProviderRoutingRule,
  type ProviderRoutingRuleInput,
  type ProviderRoutingRulesPayload,
  type ProviderRoutingTrigger
} from "../api/providerRoutingRules"

type DraftRule = {
  id?: number
  name: string
  triggerKey: string
  workflowTriggerKinds: string[]
  actionStrategy: string
  candidates: ProviderRoutingCandidate[]
}

type DraftErrors = Partial<Record<"name" | "trigger" | "candidates", string>>

export type RoutingRulesPanelProps = {
  description: string
  destroyError?: unknown
  destroyPending?: boolean
  inheritedContext?: ProviderRoutingInheritedContext[]
  onCreateRule: (input: ProviderRoutingRuleInput) => Promise<unknown> | unknown
  onDeleteRule: (rule: ProviderRoutingRule) => Promise<unknown> | unknown
  onReorderRules: (ids: number[]) => void
  onUpdateRule: (rule: ProviderRoutingRule, input: ProviderRoutingRuleInput) => Promise<unknown> | unknown
  options?: ProviderRoutingOptions
  reorderError?: unknown
  reorderPending?: boolean
  rules?: ProviderRoutingRule[]
  saveError?: unknown
  saving?: boolean
  title: string
}

const EMPTY_OPTIONS: ProviderRoutingOptions = {
  agent_providers: [],
  effort_levels: [],
  triggers: { chat_roles: [], step_kinds: [] },
  conditions: { workflow_trigger_kinds: [] },
  action_strategies: [],
  condition_keys: []
}

export function ProviderRoutingRulesEditor({
  basePath,
  description,
  inheritedContext,
  queryKey,
  rules,
  title,
  options,
  onSaved
}: {
  basePath: string
  description: string
  inheritedContext?: ProviderRoutingInheritedContext[]
  queryKey: readonly unknown[]
  rules?: ProviderRoutingRule[]
  title: string
  options?: ProviderRoutingOptions
  onSaved?: (payload: ProviderRoutingRulesPayload) => void
}) {
  const queryClient = useQueryClient()

  const save = useMutation({
    mutationFn: ({ rule, input }: { rule?: ProviderRoutingRule; input: ProviderRoutingRuleInput }) =>
      rule ? updateProviderRoutingRule(`${basePath}/${rule.id}`, input) : createProviderRoutingRule(basePath, input),
    onSuccess: (payload) => {
      onSaved?.(payload)
      void queryClient.invalidateQueries({ queryKey })
    }
  })
  const destroy = useMutation({
    mutationFn: (rule: ProviderRoutingRule) => deleteProviderRoutingRule(`${basePath}/${rule.id}`),
    onSuccess: (payload) => {
      onSaved?.(payload)
      void queryClient.invalidateQueries({ queryKey })
    }
  })
  const reorder = useMutation({
    mutationFn: (ids: number[]) => reorderProviderRoutingRules(basePath, ids),
    onSuccess: (payload) => {
      onSaved?.(payload)
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  return (
    <RoutingRulesPanel
      description={description}
      destroyError={destroy.error}
      destroyPending={destroy.isPending}
      inheritedContext={inheritedContext}
      onCreateRule={(input) => save.mutateAsync({ input })}
      onDeleteRule={(rule) => destroy.mutateAsync(rule)}
      onReorderRules={(ids) => reorder.mutate(ids)}
      onUpdateRule={(rule, input) => save.mutateAsync({ rule, input })}
      options={options}
      reorderError={reorder.error}
      reorderPending={reorder.isPending}
      rules={rules}
      saveError={save.error}
      saving={save.isPending}
      title={title}
    />
  )
}

export function RoutingRulesPanel({
  description,
  destroyError,
  destroyPending = false,
  inheritedContext,
  onCreateRule,
  onDeleteRule,
  onReorderRules,
  onUpdateRule,
  options,
  reorderError,
  reorderPending = false,
  rules,
  saveError,
  saving = false,
  title
}: RoutingRulesPanelProps) {
  const { t } = useT("settings")
  const routingOptions = normalizeOptions(options)
  const routingRules = rules || []
  const inheritedRows = (inheritedContext || []).filter((context) => context.rules.length > 0)
  const [draft, setDraft] = useState<DraftRule | null>(null)
  const [draftErrors, setDraftErrors] = useState<DraftErrors>({})

  function openNewRule() {
    setDraft(emptyDraft(routingOptions))
    setDraftErrors({})
  }

  function edit(rule: ProviderRoutingRule) {
    setDraft(draftFromRule(rule, routingOptions))
    setDraftErrors({})
  }

  function duplicate(rule: ProviderRoutingRule) {
    const copy = draftFromRule(rule, routingOptions)
    setDraft({ ...copy, id: undefined, name: t("provider_routing.copy_name", { name: copy.name }) })
    setDraftErrors({})
  }

  function closeEditor() {
    setDraft(null)
    setDraftErrors({})
  }

  async function submitDraft() {
    if (!draft) return

    const nextErrors = validateDraft(draft, t)
    setDraftErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    const input = draftToInput(draft)
    try {
      if (draft.id) {
        const rule = routingRules.find((candidate) => candidate.id === draft.id)
        if (rule) await onUpdateRule(rule, input)
      } else {
        await onCreateRule(input)
      }
    } catch {
      return
    }
    closeEditor()
  }

  async function deleteRule(rule: ProviderRoutingRule) {
    try {
      await onDeleteRule(rule)
    } catch {
      return
    }

    if (draft?.id === rule.id) closeEditor()
  }

  function move(rule: ProviderRoutingRule, direction: -1 | 1) {
    const index = routingRules.findIndex((candidate) => candidate.id === rule.id)
    const nextIndex = index + direction
    if (index < 0 || nextIndex < 0 || nextIndex >= routingRules.length) return

    const ids = routingRules.map((candidate) => candidate.id)
    const [id] = ids.splice(index, 1)
    ids.splice(nextIndex, 0, id)
    onReorderRules(ids)
  }

  return (
    <section className="space-y-4 border-t border-border pt-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h3 className="text-sm font-medium text-text-primary">{title}</h3>
          <p className="mt-1 text-xs text-text-secondary">{description}</p>
          <p className="mt-1 text-xs font-medium text-text-primary">{t("provider_routing.first_match_wins")}</p>
        </div>
        <Button onClick={openNewRule} size="sm">{t("provider_routing.new_rule")}</Button>
      </div>

      {routingRules.length > 0 || inheritedRows.length > 0 ? (
        <div className="space-y-3">
          <RulesTable
            destroyPending={destroyPending}
            onDelete={deleteRule}
            onDuplicate={duplicate}
            onEdit={edit}
            onMove={move}
            options={routingOptions}
            reorderPending={reorderPending}
            rules={routingRules}
            t={t}
          />
          {inheritedRows.map((context) => (
            <RulesTable
              inheritedLabel={context.label}
              key={`${context.scope_type}-${context.scope_id}`}
              options={routingOptions}
              readOnly
              rules={context.rules}
              t={t}
            />
          ))}
        </div>
      ) : (
        <Surface padding="sm" variant="subtle">
          <p className="text-sm font-medium text-text-primary">{t("provider_routing.empty")}</p>
          <p className="mt-1 text-xs text-text-secondary">{t("provider_routing.empty_description")}</p>
        </Surface>
      )}

      {saveError ? <PanelMessage tone="error">{errorMessage(saveError, t("provider_routing.save_error"))}</PanelMessage> : null}
      {destroyError ? <PanelMessage tone="error">{errorMessage(destroyError, t("provider_routing.delete_error"))}</PanelMessage> : null}
      {reorderError ? <PanelMessage tone="error">{errorMessage(reorderError, t("provider_routing.reorder_error"))}</PanelMessage> : null}

      <RuleEditorModal
        draft={draft}
        errors={draftErrors}
        onClose={closeEditor}
        onSave={submitDraft}
        onUpdate={(nextDraft) => {
          setDraft(nextDraft)
          setDraftErrors({})
        }}
        options={routingOptions}
        saving={saving}
        t={t}
      />
    </section>
  )
}

function RulesTable({
  destroyPending = false,
  inheritedLabel,
  onDelete,
  onDuplicate,
  onEdit,
  onMove,
  options,
  readOnly = false,
  reorderPending = false,
  rules,
  t
}: {
  destroyPending?: boolean
  inheritedLabel?: string
  onDelete?: (rule: ProviderRoutingRule) => void
  onDuplicate?: (rule: ProviderRoutingRule) => void
  onEdit?: (rule: ProviderRoutingRule) => void
  onMove?: (rule: ProviderRoutingRule, direction: -1 | 1) => void
  options: ProviderRoutingOptions
  readOnly?: boolean
  reorderPending?: boolean
  rules: ProviderRoutingRule[]
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const table = (
    <DataTable.Root
      aria-label={inheritedLabel || t("provider_routing.rules_table")}
      density="compact"
      wrapperClassName={inheritedLabel ? "rounded-t-none border-x-0 border-b-0" : ""}
    >
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell className="w-20">{t("provider_routing.order")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("provider_routing.rule")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("provider_routing.match")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("provider_routing.action")}</DataTable.HeadCell>
          <DataTable.HeadCell align="right">{t("provider_routing.actions")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body className="divide-y divide-border">
        {rules.map((rule, index) => (
          <DataTable.Row className={readOnly ? "bg-surface-subtle/50" : "bg-surface"} key={rule.id}>
            <DataTable.Cell className="whitespace-nowrap align-top">
              <div className="flex items-center gap-1">
                <span className="w-6 text-xs font-medium text-text-secondary">{index + 1}</span>
                {!readOnly ? (
                  <div className="flex gap-1">
                    <Button
                      aria-label={t("provider_routing.move_up_aria", { name: ruleName(rule, t) })}
                      className="h-7 w-7"
                      disabled={index === 0 || reorderPending}
                      onClick={() => onMove?.(rule, -1)}
                      size="icon"
                      variant="secondary"
                    >
                      <ChevronIcon className="h-4 w-4 -rotate-90" />
                    </Button>
                    <Button
                      aria-label={t("provider_routing.move_down_aria", { name: ruleName(rule, t) })}
                      className="h-7 w-7"
                      disabled={index === rules.length - 1 || reorderPending}
                      onClick={() => onMove?.(rule, 1)}
                      size="icon"
                      variant="secondary"
                    >
                      <ChevronIcon className="h-4 w-4 rotate-90" />
                    </Button>
                  </div>
                ) : null}
              </div>
            </DataTable.Cell>
            <DataTable.Cell className="min-w-44 align-top">
              <div className="font-medium text-text-primary">{ruleName(rule, t)}</div>
              <div className="mt-1 text-xs text-text-secondary">{taskKeyLabel(rule.task_key, t)}</div>
            </DataTable.Cell>
            <DataTable.Cell className="min-w-56 align-top">
              <div className="flex flex-wrap gap-1.5">
                <Pill tone="info" wrap>{triggerLabel(rule.trigger, options, t)}</Pill>
                {conditionPills(rule, options, t).map((label) => <Pill key={label} tone="neutral" wrap>{label}</Pill>)}
              </div>
            </DataTable.Cell>
            <DataTable.Cell className="min-w-64 align-top text-xs text-text-secondary">
              <div className="font-medium text-text-primary">{actionStrategyLabel(actionStrategy(rule), options, t)}</div>
              <ol className="mt-1 list-decimal space-y-1 pl-4">
                {ruleCandidates(rule).map((candidate, candidateIndex) => (
                  <li key={`${rule.id}-${candidateIndex}`}>{candidateLabel(candidate, options, t)}</li>
                ))}
              </ol>
            </DataTable.Cell>
            <DataTable.Cell align="right" className="align-top">
              <div className="flex justify-end gap-2">
                {readOnly ? <Pill tone="neutral">{t("provider_routing.read_only")}</Pill> : (
                  <>
                    <Button onClick={() => onEdit?.(rule)} size="sm" variant="secondary">{t("provider_routing.edit")}</Button>
                    <Button onClick={() => onDuplicate?.(rule)} size="sm" variant="secondary">{t("provider_routing.duplicate")}</Button>
                    <Button disabled={destroyPending} onClick={() => { void onDelete?.(rule) }} size="sm" variant="danger">{t("provider_routing.delete")}</Button>
                  </>
                )}
              </div>
            </DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )

  if (!inheritedLabel) return table

  return (
    <div className="overflow-hidden rounded-[var(--radius-panel)] border border-[length:var(--border-width)] border-border bg-surface">
      {inheritedLabel ? (
        <div className="flex items-center justify-between border-b border-border px-3 py-2">
          <span className="text-xs font-medium text-text-secondary">{inheritedLabel}</span>
          <Pill tone="neutral">{t("provider_routing.inherited")}</Pill>
        </div>
      ) : null}
      {table}
    </div>
  )
}

function RuleEditorModal({
  draft,
  errors,
  onClose,
  onSave,
  onUpdate,
  options,
  saving,
  t
}: {
  draft: DraftRule | null
  errors: DraftErrors
  onClose: () => void
  onSave: () => void
  onUpdate: (draft: DraftRule) => void
  options: ProviderRoutingOptions
  saving: boolean
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const titleId = "provider-routing-rule-editor-title"
  if (!draft) return null
  const currentDraft = draft
  const triggerOptions = triggerSelectOptions(options, t, currentDraft.triggerKey)

  function updateCandidate(index: number, candidate: ProviderRoutingCandidate) {
    onUpdate({
      ...currentDraft,
      candidates: currentDraft.candidates.map((item, itemIndex) => itemIndex === index ? candidate : item)
    })
  }

  function submitOnTextInputEnter(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "Enter") return
    if (event.nativeEvent.isComposing) return
    if (saving) return
    if (!(event.target instanceof HTMLInputElement)) return

    event.preventDefault()
    event.stopPropagation()
    onSave()
  }

  return (
    <Modal
      className="max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]"
      labelledBy={titleId}
      onClose={onClose}
      open={Boolean(draft)}
    >
      <div className="space-y-5" onKeyDown={submitOnTextInputEnter}>
        <div>
          <h2 className="text-base font-semibold text-text-primary" id={titleId}>
            {currentDraft.id ? t("provider_routing.edit_rule_title") : t("provider_routing.new_rule_title")}
          </h2>
          <p className="mt-1 text-xs text-text-secondary">{t("provider_routing.modal_description")}</p>
        </div>

        <Form.Field error={errors.name}>
          <Form.Label required>{t("provider_routing.rule_name")}</Form.Label>
          <Form.Input onChange={(event) => onUpdate({ ...currentDraft, name: event.target.value })} value={currentDraft.name} />
          <Form.ErrorText />
        </Form.Field>

        <div className="grid gap-3 sm:grid-cols-2">
          <Form.Field error={errors.trigger}>
            <Form.Label required>{t("provider_routing.trigger")}</Form.Label>
            <Form.Select onChange={(event) => onUpdate({ ...currentDraft, triggerKey: event.target.value })} value={currentDraft.triggerKey}>
              {triggerOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </Form.Select>
            <Form.ErrorText />
          </Form.Field>
          <Form.Field>
            <Form.Label>{t("provider_routing.action_type")}</Form.Label>
            <Form.Select onChange={(event) => onUpdate({ ...currentDraft, actionStrategy: event.target.value })} value={currentDraft.actionStrategy}>
              {actionStrategyOptions(options).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </Form.Select>
          </Form.Field>
        </div>

        <Form.Field>
          <Form.Label>{t("provider_routing.workflow_conditions")}</Form.Label>
          <Form.Select
            multiple
            onChange={(event) => {
              const selected = Array.from(event.currentTarget.selectedOptions).map((option) => option.value)
              onUpdate({ ...currentDraft, workflowTriggerKinds: selected })
            }}
            value={currentDraft.workflowTriggerKinds}
          >
            {(options.conditions?.workflow_trigger_kinds || []).map((option) => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </Form.Select>
          <Form.HelpText>{t("provider_routing.workflow_conditions_help")}</Form.HelpText>
        </Form.Field>

        <div className="space-y-2">
          <div>
            <div className="text-sm font-medium text-text-primary">{t("provider_routing.provider_candidates")}</div>
            <p className="mt-1 text-xs text-text-secondary">{t("provider_routing.provider_candidates_help")}</p>
          </div>
          {currentDraft.candidates.map((candidate, index) => (
            <RoutingCandidateRow
              candidate={candidate}
              key={index}
              onChange={(next) => updateCandidate(index, next)}
              onRemove={() => onUpdate({ ...currentDraft, candidates: currentDraft.candidates.filter((_, itemIndex) => itemIndex !== index) })}
              options={options}
              removable={currentDraft.candidates.length > 1}
              t={t}
            />
          ))}
          {errors.candidates ? <p className="text-xs font-medium text-danger-text" role="alert">{errors.candidates}</p> : null}
          <Button onClick={() => onUpdate({ ...currentDraft, candidates: [...currentDraft.candidates, emptyCandidate(options)] })} size="sm" variant="secondary">
            {t("provider_routing.add_candidate")}
          </Button>
        </div>

        <Form.Actions>
          <Button onClick={onClose} variant="secondary">{t("provider_routing.cancel")}</Button>
          <Button disabled={saving} onClick={onSave}>{currentDraft.id ? t("provider_routing.save_rule") : t("provider_routing.create_rule")}</Button>
        </Form.Actions>
      </div>
    </Modal>
  )
}

function RoutingCandidateRow({
  candidate,
  onChange,
  onRemove,
  options,
  removable,
  t
}: {
  candidate: ProviderRoutingCandidate
  onChange: (candidate: ProviderRoutingCandidate) => void
  onRemove: () => void
  options: ProviderRoutingOptions
  removable: boolean
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const provider = providerOption(options, candidate.provider)
  return (
    <div className="grid gap-2 rounded border border-border p-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_9rem_auto]">
      <Select aria-label={t("provider_routing.provider")} onChange={(event) => onChange({ provider: event.target.value, model: null, effort_level: candidate.effort_level || null })} value={candidate.provider}>
        {options.agent_providers.length === 0 ? <option value=""></option> : null}
        {options.agent_providers.map((option) => <option disabled={option.configured === false} key={option.value} value={option.value}>{option.label}</option>)}
      </Select>
      <Select aria-label={t("provider_routing.model")} onChange={(event) => onChange({ ...candidate, model: event.target.value || null })} value={candidate.model || ""}>
        <option value="">{t("provider_routing.provider_default_model")}</option>
        {(provider?.models || []).map((model) => <option key={model.id} value={model.id}>{model.label}</option>)}
      </Select>
      <Select aria-label={t("provider_routing.effort")} onChange={(event) => onChange({ ...candidate, effort_level: event.target.value || null })} value={candidate.effort_level || ""}>
        <option value="">{t("provider_routing.default_effort")}</option>
        {options.effort_levels.map((effort) => <option key={effort.value} value={effort.value}>{effortLabel(effort.value, effort.label, t)}</option>)}
      </Select>
      <Button disabled={!removable} onClick={onRemove} size="sm" variant="secondary">{t("provider_routing.remove")}</Button>
    </div>
  )
}

function normalizeOptions(options?: ProviderRoutingOptions): ProviderRoutingOptions {
  return {
    agent_providers: options?.agent_providers || EMPTY_OPTIONS.agent_providers,
    effort_levels: options?.effort_levels || EMPTY_OPTIONS.effort_levels,
    triggers: {
      chat_roles: options?.triggers?.chat_roles || [],
      step_kinds: options?.triggers?.step_kinds || []
    },
    conditions: {
      workflow_trigger_kinds: options?.conditions?.workflow_trigger_kinds || []
    },
    action_strategies: options?.action_strategies || [],
    condition_keys: options?.condition_keys || []
  }
}

function emptyCandidate(options: ProviderRoutingOptions): ProviderRoutingCandidate {
  return { provider: options.agent_providers[0]?.value || "", model: null, effort_level: null }
}

function emptyDraft(options: ProviderRoutingOptions): DraftRule {
  return {
    name: "",
    triggerKey: "default",
    workflowTriggerKinds: [],
    actionStrategy: actionStrategyOptions(options)[0]?.value || "fallback_order",
    candidates: [emptyCandidate(options)]
  }
}

function draftFromRule(rule: ProviderRoutingRule, options: ProviderRoutingOptions): DraftRule {
  return {
    id: rule.id,
    name: ruleName(rule, () => "Default routing"),
    triggerKey: triggerToKey(rule.trigger),
    workflowTriggerKinds: stringList(rule.conditions?.workflow_trigger_kind),
    actionStrategy: actionStrategy(rule),
    candidates: ruleCandidates(rule).length > 0 ? ruleCandidates(rule) : [emptyCandidate(options)]
  }
}

function validateDraft(draft: DraftRule, t: (key: string, options?: Record<string, unknown>) => string): DraftErrors {
  const errors: DraftErrors = {}
  if (!draft.name.trim()) errors.name = t("provider_routing.validation_name")
  if (!draft.triggerKey) errors.trigger = t("provider_routing.validation_trigger")
  if (!draft.candidates.some((candidate) => candidate.provider)) errors.candidates = t("provider_routing.validation_candidates")
  return errors
}

function draftToInput(draft: DraftRule): ProviderRoutingRuleInput {
  const candidates = draft.candidates.filter((candidate) => candidate.provider)
  const trigger = keyToTrigger(draft.triggerKey)
  const conditions: ProviderRoutingConditions = {}
  if (draft.workflowTriggerKinds.length > 0) conditions.workflow_trigger_kind = draft.workflowTriggerKinds
  const action: ProviderRoutingAction = { strategy: draft.actionStrategy, candidates, name: draft.name.trim() }

  return {
    task_key: taskKeyForTrigger(trigger),
    trigger,
    conditions,
    action,
    candidates
  }
}

function triggerSelectOptions(options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string, selectedKey?: string) {
  const registryOptions = [
    { value: "default", label: t("provider_routing.trigger_default") },
    ...(options.triggers?.step_kinds || []).map((option) => ({ value: `step:${option.value}`, label: t("provider_routing.trigger_step", { label: option.label }) })),
    ...(options.triggers?.chat_roles || []).map((option) => ({ value: `chat_role:${option.value}`, label: t("provider_routing.trigger_chat_role", { label: option.label }) }))
  ]
  if (selectedKey?.startsWith("legacy_task:") && !registryOptions.some((option) => option.value === selectedKey)) {
    const taskKey = selectedKey.slice("legacy_task:".length)
    return [...registryOptions, { value: selectedKey, label: t("provider_routing.trigger_legacy_task", { taskKey }) }]
  }

  return registryOptions
}

function actionStrategyOptions(options: ProviderRoutingOptions) {
  return options.action_strategies?.length ? options.action_strategies : [
    { value: "fallback_order", label: "Fallback order" },
    { value: "weighted", label: "Weighted" }
  ]
}

function keyToTrigger(key: string): ProviderRoutingTrigger {
  if (key.startsWith("step:")) return { type: "step", kind: key.slice("step:".length) }
  if (key.startsWith("chat_role:")) return { type: "chat_role", role: key.slice("chat_role:".length) }
  if (key.startsWith("legacy_task:")) return { type: "legacy_task", task_key: key.slice("legacy_task:".length) }
  return { type: "default" }
}

function triggerToKey(trigger?: ProviderRoutingTrigger) {
  if (trigger?.type === "step") return `step:${trigger.kind}`
  if (trigger?.type === "chat_role") return `chat_role:${trigger.role}`
  if (trigger?.type === "legacy_task") return `legacy_task:${trigger.task_key}`
  return "default"
}

function taskKeyForTrigger(trigger: ProviderRoutingTrigger) {
  if (trigger.type === "step") return trigger.kind
  if (trigger.type === "chat_role") return trigger.role
  if (trigger.type === "legacy_task") return trigger.task_key
  return "default"
}

function providerOption(options: ProviderRoutingOptions, provider: string) {
  return options.agent_providers.find((option) => option.value === provider)
}

function ruleCandidates(rule: ProviderRoutingRule) {
  return rule.action?.candidates?.length ? rule.action.candidates : rule.candidates
}

function actionStrategy(rule: ProviderRoutingRule) {
  return rule.action?.strategy || "fallback_order"
}

function ruleName(rule: ProviderRoutingRule, t: (key: string, options?: Record<string, unknown>) => string) {
  const name = typeof rule.action?.name === "string" ? rule.action.name.trim() : ""
  return name || (rule.task_key === "default" ? t("provider_routing.default_rule_name") : rule.task_key)
}

function taskKeyLabel(taskKey: string, t: (key: string, options?: Record<string, unknown>) => string) {
  return taskKey === "default" ? t("provider_routing.default_task_key") : taskKey
}

function triggerLabel(trigger: ProviderRoutingTrigger | undefined, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  if (trigger?.type === "step") return t("provider_routing.trigger_step", { label: optionLabel(options.triggers?.step_kinds, trigger.kind) || trigger.kind })
  if (trigger?.type === "chat_role") return t("provider_routing.trigger_chat_role", { label: optionLabel(options.triggers?.chat_roles, trigger.role) || trigger.role })
  if (trigger?.type === "legacy_task") return t("provider_routing.trigger_legacy_task", { taskKey: trigger.task_key })
  return t("provider_routing.trigger_default")
}

function conditionPills(rule: ProviderRoutingRule, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  const labels: string[] = []
  const workflowKinds = stringList(rule.conditions?.workflow_trigger_kind)
  workflowKinds.forEach((kind) => labels.push(t("provider_routing.workflow_condition_pill", { label: optionLabel(options.conditions?.workflow_trigger_kinds, String(kind)) || String(kind) })))
  Object.keys(rule.conditions || {}).filter((key) => key !== "workflow_trigger_kind").forEach((key) => labels.push(key))
  return labels
}

function stringList(value: unknown) {
  return (Array.isArray(value) ? value : value == null ? [] : [value])
    .map((entry) => String(entry).trim())
    .filter(Boolean)
}

function optionLabel(options: Array<{ value: string; label: string }> | undefined, value: string) {
  return options?.find((option) => option.value === value)?.label
}

function actionStrategyLabel(strategy: string, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  return optionLabel(actionStrategyOptions(options), strategy) || t(`provider_routing.action_strategies.${strategy}`, { defaultValue: strategy })
}

function candidateLabel(candidate: ProviderRoutingCandidate, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  const provider = providerOption(options, candidate.provider)
  const model = provider?.models.find((entry) => entry.id === candidate.model)
  const effort = options.effort_levels.find((entry) => entry.value === candidate.effort_level)
  return [
    provider?.label || candidate.provider,
    model ? model.label : candidate.model,
    candidate.effort_level ? t("provider_routing.effort_candidate", { effort: effortLabel(candidate.effort_level, effort?.label || candidate.effort_level, t) }) : null
  ].filter(Boolean).join(" / ")
}

function effortLabel(value: string, fallback: string, t: (key: string, options?: Record<string, unknown>) => string) {
  return t(`provider_routing.effort_levels.${value}`, { defaultValue: fallback })
}
