import { useEffect, useRef, useState } from "react"
import type { DragEvent, KeyboardEvent, SVGProps } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Button } from "./Button"
import { Modal } from "./Modal"
import { RoutingTestPanel } from "./ProviderRoutingTestPanel"
import { PanelMessage } from "./PanelMessage"
import { Select } from "./Select"
import { Checkbox, Form, Pill, Surface } from "./ui"
import { errorMessage } from "../lib/errorMessage"
import { useT } from "../hooks/useT"
import { matchingReviewContribution, renderReviewContribution } from "../pluginReviewContributions"
import {
  activeConditionTypes,
  availableConditionTypes,
  conditionSummaries,
  conditionsError,
  pruneEmptyConditions,
  type ConditionScope
} from "./providerRoutingConditions"
import {
  createProviderRoutingRule,
  deleteProviderRoutingRule,
  explainProviderRouting,
  reorderProviderRoutingRules,
  updateProviderRoutingRule,
  type ProviderRoutingAction,
  type ProviderRoutingExplainInput,
  type ProviderRoutingExplanation,
  type ProviderRoutingCandidate,
  type ProviderRoutingConditions,
  type ProviderRoutingInheritedContext,
  type ProviderRoutingOptions,
  type ProviderRoutingRule,
  type ProviderRoutingRuleInput,
  type ProviderRoutingTrigger
} from "../api/providerRoutingRules"

type DraftRule = {
  id?: number
  name: string
  triggerKey: string
  conditions: ProviderRoutingConditions
  actionType: "route" | "hold"
  actionStrategy: string
  panelConsensus: "unanimous" | "majority" | "at_least"
  panelAtLeast: number
  panelUnavailable: "drop" | "hold" | "fail"
  panelMinMembers: number
  candidates: ProviderRoutingCandidate[]
  holdReason: string
  resumptionMode: string
  resumeAt: string
}

type DraftErrors = Partial<Record<"name" | "trigger" | "candidates" | "panel" | "holdReason" | "resumeAt" | "conditions", string>>

export type RoutingRulesPanelProps = {
  description: string
  destroyError?: unknown
  destroyPending?: boolean
  inheritedContext?: ProviderRoutingInheritedContext[]
  onCreateRule: (input: ProviderRoutingRuleInput) => Promise<unknown> | unknown
  onDeleteRule: (rule: ProviderRoutingRule) => Promise<unknown> | unknown
  /** Enables the Test entry point; runs the rule set against a Job. */
  onExplain?: (input: ProviderRoutingExplainInput) => Promise<ProviderRoutingExplanation>
  onReorderRules: (ids: number[]) => void
  onToggleRule?: (rule: ProviderRoutingRule, enabled: boolean) => Promise<unknown> | unknown
  onUpdateRule: (rule: ProviderRoutingRule, input: ProviderRoutingRuleInput) => Promise<unknown> | unknown
  options?: ProviderRoutingOptions
  reorderError?: unknown
  reorderPending?: boolean
  rules?: ProviderRoutingRule[]
  /** Scope of the rule set being edited; hides conditions that are redundant there. */
  scope?: ConditionScope
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

const DRAG_HANDLE_CLASSES =
  "self-stretch rounded text-text-secondary hover:bg-surface-raised hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-60"

export function ProviderRoutingRulesEditor({
  basePath,
  description,
  inheritedContext,
  queryKey,
  rules,
  title,
  options,
  onSaved,
  scope
}: {
  basePath: string
  description: string
  inheritedContext?: ProviderRoutingInheritedContext[]
  queryKey: readonly unknown[]
  rules?: ProviderRoutingRule[]
  title: string
  options?: ProviderRoutingOptions
  onSaved?: () => void
  scope?: ConditionScope
}) {
  const queryClient = useQueryClient()
  const [displayRules, setDisplayRules] = useState(rules || [])

  useEffect(() => setDisplayRules(rules || []), [rules])

  const save = useMutation({
    mutationFn: ({ rule, input }: { rule?: ProviderRoutingRule; input: ProviderRoutingRuleInput }) =>
      rule ? updateProviderRoutingRule(`${basePath}/${rule.id}`, input) : createProviderRoutingRule(basePath, input),
    onSuccess: () => {
      onSaved?.()
      void queryClient.invalidateQueries({ queryKey })
    }
  })
  const destroy = useMutation({
    mutationFn: (rule: ProviderRoutingRule) => deleteProviderRoutingRule(`${basePath}/${rule.id}`),
    onSuccess: () => {
      onSaved?.()
      void queryClient.invalidateQueries({ queryKey })
    }
  })
  const reorder = useMutation({
    mutationFn: ({ ids }: { ids: number[]; previousRules: ProviderRoutingRule[] }) => reorderProviderRoutingRules(basePath, ids),
    onSuccess: () => {
      onSaved?.()
      void queryClient.invalidateQueries({ queryKey })
    },
    onError: (_error, variables) => setDisplayRules(variables.previousRules)
  })

  function reorderOptimistically(ids: number[]) {
    const previousRules = displayRules
    setDisplayRules(ids.map((id) => displayRules.find((rule) => rule.id === id)).filter((rule): rule is ProviderRoutingRule => Boolean(rule)))
    reorder.mutate({ ids, previousRules })
  }

  return (
    <RoutingRulesPanel
      description={description}
      destroyError={destroy.error}
      destroyPending={destroy.isPending}
      inheritedContext={inheritedContext}
      onCreateRule={(input) => save.mutateAsync({ input })}
      onDeleteRule={(rule) => destroy.mutateAsync(rule)}
      onExplain={(input) => explainProviderRouting(basePath, input)}
      onReorderRules={reorderOptimistically}
      onToggleRule={(rule, enabled) => save.mutateAsync({ rule, input: ruleToInput(rule, { enabled }) })}
      onUpdateRule={(rule, input) => save.mutateAsync({ rule, input })}
      options={options}
      reorderError={reorder.error}
      reorderPending={reorder.isPending}
      rules={displayRules}
      scope={scope}
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
  onExplain,
  onReorderRules,
  onToggleRule,
  onUpdateRule,
  options,
  reorderError,
  reorderPending = false,
  rules,
  saveError,
  saving = false,
  scope = "user",
  title
}: RoutingRulesPanelProps) {
  const { t } = useT("settings")
  const routingOptions = normalizeOptions(options)
  const routingRules = rules || []
  const inheritedRows = (inheritedContext || []).filter((context) => context.rules.length > 0)
  const [draft, setDraft] = useState<DraftRule | null>(null)
  const [draftErrors, setDraftErrors] = useState<DraftErrors>({})
  const [testing, setTesting] = useState(false)
  const settingsSummaries = (routingOptions.review_contributions || []).filter((entry) => entry.kind === "settings_summary")

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

    const nextErrors = validateDraft(draft, routingOptions, t)
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
        <div className="flex flex-wrap gap-2">
          {onExplain ? (
            <Button aria-expanded={testing} onClick={() => setTesting((open) => !open)} size="sm" variant="secondary">
              {t("provider_routing.test.button")}
            </Button>
          ) : null}
          <Button onClick={openNewRule} size="sm">
            {t("provider_routing.new_rule")}
          </Button>
        </div>
      </div>
      {settingsSummaries.map((contribution) => (
        <div key={contribution.key}>{renderReviewContribution(contribution, { options: routingOptions })}</div>
      ))}

      {testing && onExplain ? <RoutingTestPanel onClose={() => setTesting(false)} onExplain={onExplain} options={routingOptions} /> : null}

      {routingRules.length > 0 || inheritedRows.length > 0 ? (
        <div className="space-y-3">
          <RulesTable
            destroyPending={destroyPending}
            onDelete={deleteRule}
            onDuplicate={duplicate}
            onEdit={edit}
            onMove={move}
            onReorder={onReorderRules}
            onToggle={onToggleRule}
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
        scope={scope}
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
  onReorder,
  onToggle,
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
  onReorder?: (ids: number[]) => void
  onToggle?: (rule: ProviderRoutingRule, enabled: boolean) => void
  options: ProviderRoutingOptions
  readOnly?: boolean
  reorderPending?: boolean
  rules: ProviderRoutingRule[]
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const draggedRuleId = useRef<number | null>(null)

  function reorder(sourceId: number, targetId: number) {
    if (sourceId === targetId) return

    const ids = rules.map((rule) => rule.id)
    const sourceIndex = ids.indexOf(sourceId)
    const targetIndex = ids.indexOf(targetId)
    if (sourceIndex < 0 || targetIndex < 0) return

    const [id] = ids.splice(sourceIndex, 1)
    ids.splice(targetIndex, 0, id)
    onReorder?.(ids)
  }

  function startDrag(rule: ProviderRoutingRule, event: DragEvent<HTMLButtonElement>) {
    draggedRuleId.current = rule.id
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", String(rule.id))
  }

  function dropOn(rule: ProviderRoutingRule, event: DragEvent<HTMLLIElement>) {
    event.preventDefault()
    const sourceId = draggedRuleId.current
    draggedRuleId.current = null
    if (sourceId != null) reorder(sourceId, rule.id)
  }

  const table = (
    <ul aria-label={inheritedLabel || t("provider_routing.rules_table")} className="divide-y divide-border">
      {rules.map((rule) => (
        <li
          className={`grid min-w-0 grid-cols-[minmax(0,1fr)_auto] gap-2 px-3 py-2.5 ${readOnly ? "bg-surface-subtle/50" : "bg-surface"} ${rule.enabled === false ? "opacity-55" : ""}`}
          data-testid="routing-rule-row"
          key={rule.id}
          onDragOver={
            readOnly
              ? undefined
              : (event) => {
                  if (draggedRuleId.current == null) return
                  event.preventDefault()
                  event.dataTransfer.dropEffect = "move"
                }
          }
          onDrop={readOnly ? undefined : (event) => dropOn(rule, event)}
        >
          <div className="flex min-w-0 gap-2">
            {!readOnly ? (
              <button
                aria-label={t("provider_routing.drag_aria", { name: ruleName(rule, t) })}
                className={DRAG_HANDLE_CLASSES}
                disabled={reorderPending}
                draggable={!reorderPending}
                onDragEnd={() => {
                  draggedRuleId.current = null
                }}
                onDragStart={(event) => startDrag(rule, event)}
                onKeyDown={(event) => {
                  if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
                  event.preventDefault()
                  onMove?.(rule, event.key === "ArrowUp" ? -1 : 1)
                }}
                title={t("provider_routing.drag_hint")}
                type="button"
              >
                <DragHandleIcon className="h-5 w-5" />
              </button>
            ) : null}
            <div className="min-w-0 flex-1 space-y-1.5">
              <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                {!readOnly ? (
                  <Checkbox
                    aria-label={t("provider_routing.enabled_aria", { name: ruleName(rule, t) })}
                    checked={rule.enabled !== false}
                    className="h-4 w-4 accent-brand"
                    onChange={(event) => {
                      void onToggle?.(rule, event.target.checked)
                    }}
                  />
                ) : null}
                <span className="min-w-0 break-words font-medium text-text-primary">{ruleName(rule, t)}</span>
                {rule.enabled === false ? <Pill tone="neutral">{t("provider_routing.disabled")}</Pill> : null}
                {readOnly ? <Pill tone="neutral">{t("provider_routing.read_only")}</Pill> : null}
              </div>
              <div className="flex min-w-0 flex-wrap items-center gap-1.5 text-xs text-text-secondary">
                <Pill tone="info" wrap>
                  {triggerLabel(rule.trigger, options, t)}
                </Pill>
                {conditionSummaries(rule.conditions, options, t).map((label) => (
                  <Pill key={label} tone="neutral" wrap>
                    {label}
                  </Pill>
                ))}
                <span aria-hidden="true" className="mx-0.5 hidden h-4 border-l border-border sm:block" data-testid="condition-action-divider" />
                <span className="min-w-0 font-medium text-text-primary">{compactActionSummary(rule, options, t)}</span>
              </div>
            </div>
          </div>
          {!readOnly ? (
            <div aria-label={t("provider_routing.actions_aria", { name: ruleName(rule, t) })} className="flex shrink-0 items-start gap-1" role="group">
              <Button
                aria-label={t("provider_routing.edit_aria", { name: ruleName(rule, t) })}
                className="h-8 w-8"
                onClick={() => onEdit?.(rule)}
                size="icon"
                variant="secondary"
              >
                <PencilIcon className="h-4 w-4" />
              </Button>
              <Button
                aria-label={t("provider_routing.duplicate_aria", { name: ruleName(rule, t) })}
                className="h-8 w-8"
                onClick={() => onDuplicate?.(rule)}
                size="icon"
                variant="secondary"
              >
                <DuplicateIcon className="h-4 w-4" />
              </Button>
              <Button
                aria-label={t("provider_routing.delete_aria", { name: ruleName(rule, t) })}
                className="h-8 w-8"
                disabled={destroyPending}
                onClick={() => {
                  void onDelete?.(rule)
                }}
                size="icon"
                variant="danger"
              >
                <TrashIcon className="h-4 w-4" />
              </Button>
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  )

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

function DragHandleIcon({ className = "" }: SVGProps<SVGSVGElement>) {
  return (
    <svg aria-hidden="true" className={className} fill="currentColor" viewBox="0 0 20 20">
      <circle cx="7" cy="5" r="1.25" />
      <circle cx="13" cy="5" r="1.25" />
      <circle cx="7" cy="10" r="1.25" />
      <circle cx="13" cy="10" r="1.25" />
      <circle cx="7" cy="15" r="1.25" />
      <circle cx="13" cy="15" r="1.25" />
    </svg>
  )
}

function PencilIcon({ className = "" }: SVGProps<SVGSVGElement>) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="2"
      viewBox="0 0 24 24"
    >
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  )
}

function DuplicateIcon({ className = "" }: SVGProps<SVGSVGElement>) {
  return (
    <svg aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" viewBox="0 0 20 20">
      <rect height="11" rx="2" width="11" x="6" y="3" />
      <path d="M3 7v8a2 2 0 0 0 2 2h8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function TrashIcon({ className = "" }: SVGProps<SVGSVGElement>) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="1.8"
      viewBox="0 0 20 20"
    >
      <path d="M3.5 5.5h13M8 3h4l1 2.5H7L8 3Z" />
      <path d="m5.5 5.5.7 11h7.6l.7-11M8 9v4.5M12 9v4.5" />
    </svg>
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
  scope,
  t
}: {
  draft: DraftRule | null
  errors: DraftErrors
  onClose: () => void
  onSave: () => void
  onUpdate: (draft: DraftRule) => void
  options: ProviderRoutingOptions
  saving: boolean
  scope: ConditionScope
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const titleId = "provider-routing-rule-editor-title"
  if (!draft) return null
  const currentDraft = draft
  const triggerOptions = triggerSelectOptions(options, t, currentDraft.triggerKey)

  function updateCandidate(index: number, candidate: ProviderRoutingCandidate) {
    onUpdate({
      ...currentDraft,
      candidates: currentDraft.candidates.map((item, itemIndex) => (itemIndex === index ? candidate : item))
    })
  }

  function submitOnTextInputEnter(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "Enter") return
    if (event.nativeEvent.isComposing) return
    if (saving) return
    if (!(event.target instanceof HTMLInputElement)) return
    if (event.target.type === "search") return

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
              {triggerOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </Form.Select>
            <Form.ErrorText />
          </Form.Field>
          <Form.Field>
            <Form.Label>{t("provider_routing.action_type")}</Form.Label>
            <Form.Select
              onChange={(event) => onUpdate({ ...currentDraft, actionType: event.target.value as "route" | "hold" })}
              value={currentDraft.actionType}
            >
              <option value="route">{t("provider_routing.action_route")}</option>
              <option value="hold">{t("provider_routing.action_hold")}</option>
            </Form.Select>
          </Form.Field>
        </div>

        <ConditionsSection
          conditions={currentDraft.conditions}
          onChange={(conditions) => onUpdate({ ...currentDraft, conditions })}
          options={options}
          scope={scope}
          t={t}
        />
        {errors.conditions ? (
          <p className="text-xs text-danger" role="alert">
            {errors.conditions}
          </p>
        ) : null}

        {currentDraft.actionType === "route" ? (
          <div className="space-y-3">
            <Form.Field>
              <Form.Label>{t("provider_routing.routing_strategy")}</Form.Label>
              <Form.Select onChange={(event) => onUpdate({ ...currentDraft, actionStrategy: event.target.value })} value={currentDraft.actionStrategy}>
                {actionStrategyOptions(options, t).map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </Form.Select>
            </Form.Field>
            {currentDraft.actionStrategy === "panel" ? (
              <div className="grid gap-3 sm:grid-cols-2">
                <Form.Field error={errors.panel}>
                  <Form.Label required>{t("provider_routing.panel_consensus")}</Form.Label>
                  <Form.Select
                    onChange={(event) => onUpdate({ ...currentDraft, panelConsensus: event.target.value as DraftRule["panelConsensus"] })}
                    value={currentDraft.panelConsensus}
                  >
                    <option value="unanimous">{t("provider_routing.panel_unanimous")}</option>
                    <option value="majority">{t("provider_routing.panel_majority")}</option>
                    <option value="at_least">{t("provider_routing.panel_at_least")}</option>
                  </Form.Select>
                  <Form.ErrorText />
                </Form.Field>
                {currentDraft.panelConsensus === "at_least" ? (
                  <Form.Field>
                    <Form.Label required>{t("provider_routing.panel_required_approvals")}</Form.Label>
                    <Form.Input
                      min={1}
                      onChange={(event) => onUpdate({ ...currentDraft, panelAtLeast: Number(event.target.value) })}
                      type="number"
                      value={currentDraft.panelAtLeast}
                    />
                  </Form.Field>
                ) : null}
                <Form.Field>
                  <Form.Label required>{t("provider_routing.panel_unavailable")}</Form.Label>
                  <Form.Select
                    onChange={(event) => onUpdate({ ...currentDraft, panelUnavailable: event.target.value as DraftRule["panelUnavailable"] })}
                    value={currentDraft.panelUnavailable}
                  >
                    <option value="drop">{t("provider_routing.panel_drop")}</option>
                    <option value="hold">{t("provider_routing.panel_hold")}</option>
                    <option value="fail">{t("provider_routing.panel_fail")}</option>
                  </Form.Select>
                </Form.Field>
                <Form.Field>
                  <Form.Label required>{t("provider_routing.panel_min_members")}</Form.Label>
                  <Form.Input
                    min={1}
                    onChange={(event) => onUpdate({ ...currentDraft, panelMinMembers: Number(event.target.value) })}
                    type="number"
                    value={currentDraft.panelMinMembers}
                  />
                </Form.Field>
              </div>
            ) : null}
            <div>
              <div className="text-sm font-medium text-text-primary">{t("provider_routing.provider_candidates")}</div>
              <p className="mt-1 text-xs text-text-secondary">{t("provider_routing.provider_candidates_help")}</p>
              {["step:adversarial_review", "step:security_review", "step:coworker_review"].includes(currentDraft.triggerKey) ? (
                <p className="mt-1 text-xs text-text-secondary">
                  <span className="sr-only">{t("provider_routing.review_identity_accessibility")}</span>
                  {t(currentDraft.triggerKey === "step:coworker_review" ? "provider_routing.dedicated_coworker_help" : "provider_routing.named_reviewer_help")}
                </p>
              ) : null}
            </div>
            {currentDraft.candidates.map((candidate, index) => (
              <RoutingCandidateRow
                candidate={candidate}
                key={index}
                onChange={(next) => updateCandidate(index, next)}
                onRemove={() => onUpdate({ ...currentDraft, candidates: currentDraft.candidates.filter((_, itemIndex) => itemIndex !== index) })}
                options={options}
                removable={currentDraft.candidates.length > 1}
                reviewerTargetEnabled={["step:adversarial_review", "step:security_review", "step:coworker_review"].includes(currentDraft.triggerKey)}
                t={t}
              />
            ))}
            {errors.candidates ? (
              <p className="text-xs font-medium text-danger-text" role="alert">
                {errors.candidates}
              </p>
            ) : null}
            <Button
              onClick={() => onUpdate({ ...currentDraft, candidates: [...currentDraft.candidates, emptyCandidate(options)] })}
              size="sm"
              variant="secondary"
            >
              {t("provider_routing.add_candidate")}
            </Button>
          </div>
        ) : (
          <div className="space-y-3">
            <Form.Field error={errors.holdReason}>
              <Form.Label required>{t("provider_routing.hold_reason")}</Form.Label>
              <Form.Input onChange={(event) => onUpdate({ ...currentDraft, holdReason: event.target.value })} value={currentDraft.holdReason} />
              <Form.ErrorText />
            </Form.Field>
            <Form.Field>
              <Form.Label>{t("provider_routing.resumption_policy")}</Form.Label>
              <Form.Select onChange={(event) => onUpdate({ ...currentDraft, resumptionMode: event.target.value })} value={currentDraft.resumptionMode}>
                <option value="manual">{t("provider_routing.resume_manual")}</option>
                <option value="when_conditions_clear">{t("provider_routing.resume_conditions_clear")}</option>
                <option value="until_time">{t("provider_routing.resume_at_time")}</option>
              </Form.Select>
            </Form.Field>
            {currentDraft.resumptionMode === "until_time" ? (
              <Form.Field error={errors.resumeAt}>
                <Form.Label required>{t("provider_routing.resume_time")}</Form.Label>
                <Form.Input
                  onChange={(event) => onUpdate({ ...currentDraft, resumeAt: event.target.value })}
                  type="datetime-local"
                  value={currentDraft.resumeAt}
                />
                <Form.ErrorText />
              </Form.Field>
            ) : null}
          </div>
        )}

        <Form.Actions>
          <Button onClick={onClose} variant="secondary">
            {t("provider_routing.cancel")}
          </Button>
          <Button disabled={saving} onClick={onSave}>
            {currentDraft.id ? t("provider_routing.save_rule") : t("provider_routing.create_rule")}
          </Button>
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
  reviewerTargetEnabled,
  t
}: {
  candidate: ProviderRoutingCandidate
  onChange: (candidate: ProviderRoutingCandidate) => void
  onRemove: () => void
  options: ProviderRoutingOptions
  removable: boolean
  reviewerTargetEnabled: boolean
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const provider = providerOption(options, candidate.provider)
  const targetType = candidate.reviewer_target?.type || options.reviewer_targets?.[0]?.type
  const targetEditor = matchingReviewContribution(options.review_contributions || [], "target_editor", { targetType })
  const targetSelect = (
    <Select
      aria-label={t("provider_routing.reviewer_target")}
      onChange={(event) => {
        const target = options.reviewer_targets?.find((item) => `${item.type}:${item.reference}` === event.target.value)
        onChange({ ...candidate, reviewer_target: target || null })
      }}
      value={candidate.reviewer_target ? `${candidate.reviewer_target.type}:${candidate.reviewer_target.reference}` : ""}
    >
      <option value="">{t("provider_routing.unnamed_reviewer")}</option>
      {(options.reviewer_targets || []).map((target) => (
        <option key={`${target.type}:${target.reference}`} value={`${target.type}:${target.reference}`}>
          {target.display.name}
          {target.display.handle ? ` (@${target.display.handle})` : ""}
        </option>
      ))}
    </Select>
  )
  return (
    <div className="grid gap-2 rounded border border-border p-2 sm:grid-cols-[repeat(2,minmax(0,1fr))_9rem_auto]">
      <Select
        aria-label={t("provider_routing.provider")}
        onChange={(event) => onChange({ provider: event.target.value, model: null, effort_level: candidate.effort_level || null })}
        value={candidate.provider}
      >
        {options.agent_providers.length === 0 ? <option value=""></option> : null}
        {options.agent_providers.map((option) => (
          <option disabled={option.configured === false} key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </Select>
      <Select
        aria-label={t("provider_routing.model")}
        onChange={(event) => onChange({ ...candidate, model: event.target.value || null })}
        value={candidate.model || ""}
      >
        <option value="">{t("provider_routing.provider_default_model")}</option>
        {(provider?.models || []).map((model) => (
          <option key={model.id} value={model.id}>
            {model.label}
          </option>
        ))}
      </Select>
      <Select
        aria-label={t("provider_routing.effort")}
        onChange={(event) => onChange({ ...candidate, effort_level: event.target.value || null })}
        value={candidate.effort_level || ""}
      >
        <option value="">{t("provider_routing.default_effort")}</option>
        {options.effort_levels.map((effort) => (
          <option key={effort.value} value={effort.value}>
            {effortLabel(effort.value, effort.label, t)}
          </option>
        ))}
      </Select>
      {reviewerTargetEnabled
        ? targetEditor
          ? renderReviewContribution(targetEditor, { candidate, targets: options.reviewer_targets || [] }, targetSelect, (value) =>
              onChange({ ...candidate, reviewer_target: value as ProviderRoutingCandidate["reviewer_target"] })
            )
          : targetSelect
        : null}
      <Button disabled={!removable} onClick={onRemove} size="sm" variant="secondary">
        {t("provider_routing.remove")}
      </Button>
    </div>
  )
}

function ConditionsSection({
  conditions,
  onChange,
  options,
  scope,
  t
}: {
  conditions: ProviderRoutingConditions
  onChange: (conditions: ProviderRoutingConditions) => void
  options: ProviderRoutingOptions
  scope: ConditionScope
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  const [menuOpen, setMenuOpen] = useState(false)
  const active = activeConditionTypes(conditions, scope)
  const available = availableConditionTypes(conditions, scope)

  return (
    <section aria-label={t("provider_routing.conditions.title")} className="space-y-2">
      <h3 className="text-sm font-medium text-text-primary">{t("provider_routing.conditions.title")}</h3>
      {active.length === 0 ? <p className="text-xs text-text-secondary">{t("provider_routing.conditions.empty")}</p> : null}
      {active.map((type) => (
        <div className="rounded-[var(--radius-panel)] border border-[length:var(--border-width)] border-border p-3" key={type.key}>
          <div className="mb-2 flex items-center justify-between gap-2">
            <span className="text-sm font-medium text-text-primary">{t(type.labelKey)}</span>
            <Button
              aria-label={t("provider_routing.conditions.remove_aria", { label: t(type.labelKey) })}
              onClick={() => {
                const next = { ...conditions }
                delete next[type.key]
                onChange(next)
              }}
              size="sm"
              variant="secondary"
            >
              {t("provider_routing.conditions.remove")}
            </Button>
          </div>
          <type.Card onChange={(value) => onChange({ ...conditions, [type.key]: value })} options={options} t={t} value={conditions[type.key]} />
        </div>
      ))}
      {available.length > 0 ? (
        <div>
          <Button aria-expanded={menuOpen} onClick={() => setMenuOpen((open) => !open)} size="sm" variant="secondary">
            {t("provider_routing.conditions.add")}
          </Button>
          {menuOpen ? (
            <ul aria-label={t("provider_routing.conditions.add")} className="mt-1 divide-y divide-border rounded border border-border bg-surface">
              {available.map((type) => (
                <li key={type.key}>
                  <button
                    className="min-h-10 w-full px-3 text-left text-sm text-text-primary hover:bg-surface-subtle"
                    onClick={() => {
                      onChange({ ...conditions, [type.key]: type.defaultValue() })
                      setMenuOpen(false)
                    }}
                    type="button"
                  >
                    {t(type.labelKey)}
                  </button>
                </li>
              ))}
            </ul>
          ) : null}
        </div>
      ) : null}
    </section>
  )
}

function normalizeOptions(options?: ProviderRoutingOptions): ProviderRoutingOptions {
  return {
    agent_providers: options?.agent_providers || EMPTY_OPTIONS.agent_providers,
    effort_levels: options?.effort_levels || EMPTY_OPTIONS.effort_levels,
    reviewer_targets: options?.reviewer_targets || [],
    triggers: {
      chat_roles: options?.triggers?.chat_roles || [],
      step_kinds: options?.triggers?.step_kinds || []
    },
    conditions: {
      workflow_trigger_kinds: options?.conditions?.workflow_trigger_kinds || [],
      provider_usage: options?.conditions?.provider_usage || [],
      job_kinds: options?.conditions?.job_kinds || [],
      repositories: options?.conditions?.repositories || [],
      time_zone: options?.conditions?.time_zone
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
    conditions: {},
    actionType: "route",
    actionStrategy: actionStrategyOptions(options)[0]?.value || "fallback_order",
    panelConsensus: "majority",
    panelAtLeast: 2,
    panelUnavailable: "drop",
    panelMinMembers: 1,
    candidates: [emptyCandidate(options)],
    holdReason: "",
    resumptionMode: "manual",
    resumeAt: ""
  }
}

function draftFromRule(rule: ProviderRoutingRule, options: ProviderRoutingOptions): DraftRule {
  return {
    id: rule.id,
    name: ruleName(rule, () => "Default routing"),
    triggerKey: triggerToKey(rule.trigger),
    conditions: pruneEmptyConditions(rule.conditions || {}),
    actionType: rule.action?.type === "hold" ? "hold" : "route",
    actionStrategy: actionStrategy(rule),
    panelConsensus: panelConsensusMode(rule.action),
    panelAtLeast: panelAtLeast(rule.action),
    panelUnavailable: rule.action?.on_unavailable === "hold" || rule.action?.on_unavailable === "fail" ? rule.action.on_unavailable : "drop",
    panelMinMembers: typeof rule.action?.min_members === "number" ? rule.action.min_members : 1,
    candidates: ruleCandidates(rule).length > 0 ? ruleCandidates(rule) : [emptyCandidate(options)],
    holdReason: typeof rule.action?.reason === "string" ? rule.action.reason : "",
    resumptionMode:
      typeof rule.action?.resumption === "object" && rule.action.resumption
        ? String((rule.action.resumption as Record<string, unknown>).mode || "manual")
        : "manual",
    resumeAt: holdResumeAt(rule.action)
  }
}

function validateDraft(draft: DraftRule, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string): DraftErrors {
  const errors: DraftErrors = {}
  if (!draft.name.trim()) errors.name = t("provider_routing.validation_name")
  if (!draft.triggerKey) errors.trigger = t("provider_routing.validation_trigger")
  if (draft.actionType === "route" && !draft.candidates.some((candidate) => candidate.provider)) errors.candidates = t("provider_routing.validation_candidates")
  if (draft.actionType === "route" && draft.triggerKey === "step:coworker_review" && draft.candidates.some((candidate) => !candidate.reviewer_target)) {
    errors.candidates = t("provider_routing.validation_coworker_targets")
  }
  if (draft.actionType === "route" && draft.actionStrategy === "panel") {
    const distinct = new Set(draft.candidates.filter((candidate) => candidate.provider).map((candidate) => JSON.stringify(candidate))).size
    const stepKind = draft.triggerKey.startsWith("step:") ? draft.triggerKey.slice("step:".length) : ""
    const panelCapable = options.triggers?.step_kinds?.some((option) => option.value === stepKind && option.panel_capable)
    if (!panelCapable) errors.panel = t("provider_routing.validation_panel_trigger")
    else if (
      distinct < 2 ||
      draft.panelMinMembers < 1 ||
      draft.panelMinMembers > distinct ||
      (draft.panelConsensus === "at_least" && (draft.panelAtLeast < 1 || draft.panelAtLeast > distinct))
    )
      errors.panel = t("provider_routing.validation_panel_members")
  }
  const conditionsMessage = conditionsError(draft.conditions, t)
  if (conditionsMessage) errors.conditions = conditionsMessage
  if (draft.actionType === "hold" && !draft.holdReason.trim()) errors.holdReason = t("provider_routing.validation_hold_reason")
  if (draft.actionType === "hold" && draft.resumptionMode === "until_time" && !draft.resumeAt) errors.resumeAt = t("provider_routing.validation_resume_time")
  return errors
}

function draftToInput(draft: DraftRule): ProviderRoutingRuleInput {
  const candidates = draft.candidates.filter((candidate) => candidate.provider)
  const trigger = keyToTrigger(draft.triggerKey)
  const conditions = pruneEmptyConditions(draft.conditions)
  const action: ProviderRoutingAction =
    draft.actionType === "hold"
      ? {
          type: "hold",
          name: draft.name.trim(),
          reason: draft.holdReason.trim(),
          resumption: { mode: draft.resumptionMode, ...(draft.resumptionMode === "until_time" ? { at: new Date(draft.resumeAt).toISOString() } : {}) }
        }
      : {
          type: "route",
          strategy: draft.actionStrategy,
          candidates,
          name: draft.name.trim(),
          ...(draft.actionStrategy === "panel"
            ? {
                consensus: draft.panelConsensus === "at_least" ? { at_least: draft.panelAtLeast } : draft.panelConsensus,
                on_unavailable: draft.panelUnavailable,
                min_members: draft.panelMinMembers
              }
            : {})
        }

  return {
    task_key: taskKeyForTrigger(trigger),
    trigger,
    conditions,
    action,
    candidates: draft.actionType === "route" ? candidates : []
  }
}

function ruleToInput(rule: ProviderRoutingRule, overrides: Partial<ProviderRoutingRuleInput> = {}): ProviderRoutingRuleInput {
  return {
    task_key: rule.task_key,
    enabled: rule.enabled !== false,
    trigger: rule.trigger,
    conditions: rule.conditions || {},
    action: rule.action,
    candidates: rule.candidates,
    ...overrides
  }
}

function holdResumeAt(action?: ProviderRoutingAction) {
  const value = typeof action?.resumption === "object" && action.resumption ? (action.resumption as Record<string, unknown>).at : null
  if (!value) return ""
  const date = new Date(String(value))
  if (Number.isNaN(date.getTime())) return ""
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16)
}

function triggerSelectOptions(options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string, selectedKey?: string) {
  const registryOptions = [
    { value: "default", label: t("provider_routing.trigger_default") },
    ...(options.triggers?.step_kinds || []).map((option) => ({
      value: `step:${option.value}`,
      label: t("provider_routing.trigger_step", { label: option.label })
    })),
    ...(options.triggers?.chat_roles || []).map((option) => ({
      value: `chat_role:${option.value}`,
      label: t("provider_routing.trigger_chat_role", { label: option.label })
    }))
  ]
  if (selectedKey?.startsWith("legacy_task:") && !registryOptions.some((option) => option.value === selectedKey)) {
    const taskKey = selectedKey.slice("legacy_task:".length)
    return [...registryOptions, { value: selectedKey, label: t("provider_routing.trigger_legacy_task", { taskKey }) }]
  }

  return registryOptions
}

function actionStrategyOptions(options: ProviderRoutingOptions, t?: (key: string) => string) {
  return options.action_strategies?.length
    ? options.action_strategies
    : [
        { value: "fallback_order", label: t?.("provider_routing.action_strategies.fallback_order") || "fallback_order" },
        { value: "weighted", label: t?.("provider_routing.action_strategies.weighted") || "weighted" }
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

function panelConsensusMode(action?: ProviderRoutingAction): DraftRule["panelConsensus"] {
  if (action?.consensus === "unanimous" || action?.consensus === "majority") return action.consensus
  return "at_least"
}

function panelAtLeast(action?: ProviderRoutingAction) {
  return typeof action?.consensus === "object" && typeof action.consensus.at_least === "number" ? action.consensus.at_least : 2
}

function ruleName(rule: ProviderRoutingRule, t: (key: string, options?: Record<string, unknown>) => string) {
  const name = typeof rule.action?.name === "string" ? rule.action.name.trim() : ""
  return name || (rule.task_key === "default" ? t("provider_routing.default_rule_name") : rule.task_key)
}

function taskKeyLabel(taskKey: string, t: (key: string, options?: Record<string, unknown>) => string) {
  return taskKey === "default" ? t("provider_routing.default_task_key") : taskKey
}

function triggerLabel(
  trigger: ProviderRoutingTrigger | undefined,
  options: ProviderRoutingOptions,
  t: (key: string, options?: Record<string, unknown>) => string
) {
  if (trigger?.type === "step") return t("provider_routing.trigger_step", { label: optionLabel(options.triggers?.step_kinds, trigger.kind) || trigger.kind })
  if (trigger?.type === "chat_role")
    return t("provider_routing.trigger_chat_role", { label: optionLabel(options.triggers?.chat_roles, trigger.role) || trigger.role })
  if (trigger?.type === "legacy_task") return t("provider_routing.trigger_legacy_task", { taskKey: trigger.task_key })
  return t("provider_routing.trigger_default")
}

function optionLabel(options: Array<{ value: string; label: string }> | undefined, value: string) {
  return options?.find((option) => option.value === value)?.label
}

function actionStrategyLabel(strategy: string, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  return optionLabel(actionStrategyOptions(options, t), strategy) || t(`provider_routing.action_strategies.${strategy}`, { defaultValue: strategy })
}

function actionLabel(rule: ProviderRoutingRule, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  return rule.action?.type === "hold"
    ? t("provider_routing.action_hold")
    : t("provider_routing.route_summary", { strategy: actionStrategyLabel(actionStrategy(rule), options, t) })
}

const COMPACT_ROUTE_PRESENTATION: Record<string, { i18nKey: string; separator: string; showWeights?: boolean }> = {
  fallback_order: { i18nKey: "provider_routing.compact_fallback", separator: " → " },
  weighted: { i18nKey: "provider_routing.compact_load_balance", separator: " · ", showWeights: true },
  panel: { i18nKey: "provider_routing.compact_panel", separator: " · " }
}

function compactActionSummary(rule: ProviderRoutingRule, options: ProviderRoutingOptions, t: (key: string, options?: Record<string, unknown>) => string) {
  if (rule.action?.type === "hold") return t("provider_routing.compact_hold", { summary: holdSummary(rule.action, t) })

  const strategy = actionStrategy(rule)
  const presentation = COMPACT_ROUTE_PRESENTATION[strategy]
  if (!presentation) return actionLabel(rule, options, t)
  const candidates = ruleCandidates(rule)
    .map((candidate) => compactCandidateLabel(candidate, options, presentation.showWeights))
    .join(presentation.separator)
  return t(presentation.i18nKey, { candidates })
}

function compactCandidateLabel(candidate: ProviderRoutingCandidate, options: ProviderRoutingOptions, showWeight = false) {
  const provider = providerOption(options, candidate.provider)?.label || candidate.provider
  return showWeight && typeof candidate.weight === "number" ? `${provider} (${candidate.weight})` : provider
}

function holdSummary(action: ProviderRoutingAction, t: (key: string, options?: Record<string, unknown>) => string) {
  const resumption = typeof action.resumption === "object" && action.resumption ? (action.resumption as Record<string, unknown>) : {}
  const mode = String(resumption.mode || "manual")
  const policy =
    mode === "until_time" && resumption.at
      ? t("provider_routing.resume_at_summary", { time: new Date(String(resumption.at)).toLocaleString() })
      : t(`provider_routing.resume_${mode}`, { defaultValue: mode })
  return `${String(action.reason || t("provider_routing.hold_default_reason"))} · ${policy}`
}

function effortLabel(value: string, fallback: string, t: (key: string, options?: Record<string, unknown>) => string) {
  return t(`provider_routing.effort_levels.${value}`, { defaultValue: fallback })
}
