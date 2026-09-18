import { useState } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Button } from "./Button"
import { Select } from "./Select"
import { Form } from "./ui"
import { PanelMessage } from "./PanelMessage"
import { errorMessage } from "../lib/errorMessage"
import {
  createProviderRoutingRule,
  deleteProviderRoutingRule,
  updateProviderRoutingRule,
  type ProviderRoutingCandidate,
  type ProviderRoutingOptions,
  type ProviderRoutingRule,
  type ProviderRoutingRulesPayload
} from "../api/providerRoutingRules"

type DraftRule = {
  id?: number
  task_key: string
  candidates: ProviderRoutingCandidate[]
}

export function ProviderRoutingRulesEditor({
  basePath,
  description,
  queryKey,
  rules,
  title,
  options,
  onSaved
}: {
  basePath: string
  description: string
  queryKey: readonly unknown[]
  rules: ProviderRoutingRule[]
  title: string
  options: ProviderRoutingOptions
  onSaved?: (payload: ProviderRoutingRulesPayload) => void
}) {
  const queryClient = useQueryClient()
  const [draft, setDraft] = useState<DraftRule>(() => emptyDraft(options))
  const [editingId, setEditingId] = useState<number | null>(null)
  const save = useMutation({
    mutationFn: () => {
      const payload = normalizeDraft(draft)
      if (draft.id) return updateProviderRoutingRule(`${basePath}/${draft.id}`, payload)
      return createProviderRoutingRule(basePath, payload)
    },
    onSuccess: (payload) => {
      onSaved?.(payload)
      void queryClient.invalidateQueries({ queryKey })
      setDraft(emptyDraft(options))
      setEditingId(null)
    }
  })
  const destroy = useMutation({
    mutationFn: (id: number) => deleteProviderRoutingRule(`${basePath}/${id}`),
    onSuccess: (payload) => {
      onSaved?.(payload)
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  function edit(rule: ProviderRoutingRule) {
    setEditingId(rule.id)
    setDraft({
      id: rule.id,
      task_key: rule.task_key,
      candidates: rule.candidates.length > 0 ? rule.candidates : [emptyCandidate(options)]
    })
  }

  function setCandidate(index: number, candidate: ProviderRoutingCandidate) {
    setDraft((current) => ({
      ...current,
      candidates: current.candidates.map((item, itemIndex) => itemIndex === index ? candidate : item)
    }))
  }

  return (
    <section className="space-y-4 border-t border-border pt-4">
      <div>
        <h3 className="text-sm font-medium text-text-primary">{title}</h3>
        <p className="mt-1 text-xs text-text-secondary">{description}</p>
      </div>

      {rules.length > 0 ? (
        <div className="space-y-2">
          {rules.map((rule) => (
            <div className="grid gap-3 rounded border border-border p-3 sm:grid-cols-[1fr_auto] sm:items-start" key={rule.id}>
              <div className="min-w-0">
                <div className="text-sm font-medium text-text-primary">{rule.task_key}</div>
                <ol className="mt-1 list-decimal space-y-1 pl-5 text-xs text-text-secondary">
                  {rule.candidates.map((candidate, index) => (
                    <li key={`${rule.id}-${index}`}>
                      {candidateLabel(candidate, options)}
                    </li>
                  ))}
                </ol>
              </div>
              <div className="flex gap-2">
                <Button onClick={() => edit(rule)} size="sm" variant="secondary">Edit</Button>
                <Button disabled={destroy.isPending} onClick={() => destroy.mutate(rule.id)} size="sm" variant="danger">Delete</Button>
              </div>
            </div>
          ))}
        </div>
      ) : <p className="text-sm text-text-secondary">No routing rules yet.</p>}

      <div className="space-y-3 rounded border border-border p-3">
        <Form.Field>
          <Form.Label>Task key</Form.Label>
          <Form.Input onChange={(event) => setDraft({ ...draft, task_key: event.target.value })} placeholder="default" type="text" value={draft.task_key} />
        </Form.Field>
        <div className="space-y-2">
          {draft.candidates.map((candidate, index) => (
            <RoutingCandidateRow
              candidate={candidate}
              key={index}
              onChange={(next) => setCandidate(index, next)}
              onRemove={() => setDraft({ ...draft, candidates: draft.candidates.filter((_, itemIndex) => itemIndex !== index) })}
              options={options}
              removable={draft.candidates.length > 1}
            />
          ))}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button onClick={() => setDraft({ ...draft, candidates: [...draft.candidates, emptyCandidate(options)] })} size="sm" variant="secondary">Add candidate</Button>
          <Button disabled={save.isPending} onClick={() => save.mutate()} size="sm">{editingId ? "Save rule" : "Create rule"}</Button>
          {editingId ? <Button onClick={() => { setDraft(emptyDraft(options)); setEditingId(null) }} size="sm" variant="secondary">Cancel</Button> : null}
        </div>
        {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save routing rule.")}</PanelMessage> : null}
        {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete routing rule.")}</PanelMessage> : null}
      </div>
    </section>
  )
}

function RoutingCandidateRow({
  candidate,
  onChange,
  onRemove,
  options,
  removable
}: {
  candidate: ProviderRoutingCandidate
  onChange: (candidate: ProviderRoutingCandidate) => void
  onRemove: () => void
  options: ProviderRoutingOptions
  removable: boolean
}) {
  const provider = providerOption(options, candidate.provider)
  return (
    <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_9rem_auto]">
      <Select onChange={(event) => onChange({ provider: event.target.value, model: null, effort_level: candidate.effort_level || null })} value={candidate.provider}>
        {options.agent_providers.map((option) => <option disabled={option.configured === false} key={option.value} value={option.value}>{option.label}</option>)}
      </Select>
      <Select onChange={(event) => onChange({ ...candidate, model: event.target.value || null })} value={candidate.model || ""}>
        <option value="">Provider default model</option>
        {(provider?.models || []).map((model) => <option key={model.id} value={model.id}>{model.label}</option>)}
      </Select>
      <Select onChange={(event) => onChange({ ...candidate, effort_level: event.target.value || null })} value={candidate.effort_level || ""}>
        <option value="">Default effort</option>
        {options.effort_levels.map((effort) => <option key={effort.value} value={effort.value}>{effort.label}</option>)}
      </Select>
      <Button disabled={!removable} onClick={onRemove} size="sm" variant="secondary">Remove</Button>
    </div>
  )
}

function emptyCandidate(options: ProviderRoutingOptions): ProviderRoutingCandidate {
  return { provider: options.agent_providers[0]?.value || "", model: null, effort_level: null }
}

function emptyDraft(options: ProviderRoutingOptions): DraftRule {
  return { task_key: "default", candidates: [emptyCandidate(options)] }
}

function normalizeDraft(draft: DraftRule) {
  return {
    task_key: draft.task_key.trim() || "default",
    candidates: draft.candidates.filter((candidate) => candidate.provider)
  }
}

function providerOption(options: ProviderRoutingOptions, provider: string) {
  return options.agent_providers.find((option) => option.value === provider)
}

function candidateLabel(candidate: ProviderRoutingCandidate, options: ProviderRoutingOptions) {
  const provider = providerOption(options, candidate.provider)
  const model = provider?.models.find((entry) => entry.id === candidate.model)
  return [
    provider?.label || candidate.provider,
    model ? model.label : candidate.model,
    candidate.effort_level ? `${candidate.effort_level} effort` : null
  ].filter(Boolean).join(" · ")
}
