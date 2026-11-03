import { useState } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button } from "./Button"
import { PanelMessage } from "./PanelMessage"
import { Select } from "./Select"
import { Form, Surface } from "./ui"
import { errorMessage } from "../lib/errorMessage"
import { useT } from "../hooks/useT"
import { fetchPickerJobs } from "../api/jobs"
import type {
  ProviderRoutingExplainInput,
  ProviderRoutingExplanation,
  ProviderRoutingOptions,
  ProviderRoutingRuleEvidence,
  ProviderRoutingRuleTrace
} from "../api/providerRoutingRules"

type T = (key: string, options?: Record<string, unknown>) => string

const COMPARATOR_SYMBOLS: Record<string, string> = {
  remaining_percent_less_than: "<",
  remaining_percent_less_than_or_equal_to: "≤",
  remaining_percent_greater_than: ">",
  remaining_percent_greater_than_or_equal_to: "≥"
}

/**
 * Compact "test against a Job" panel for the routing rules editor. `onExplain`
 * performs the request so the panel stays scope-agnostic.
 */
export function RoutingTestPanel({
  onClose,
  onExplain,
  options
}: {
  onClose: () => void
  onExplain: (input: ProviderRoutingExplainInput) => Promise<ProviderRoutingExplanation>
  options: ProviderRoutingOptions
}) {
  const { t } = useT("settings")
  const [search, setSearch] = useState("")
  const [jobId, setJobId] = useState("")
  const taskOptions = [...(options.triggers?.step_kinds || []), ...(options.triggers?.chat_roles || [])]
  const [taskKey, setTaskKey] = useState(taskOptions[0]?.value || "")

  const jobs = useQuery({
    queryKey: ["provider-routing-test-jobs", search],
    queryFn: () => fetchPickerJobs({ q: search || undefined, limit: 10 })
  })
  const explain = useMutation({ mutationFn: (input: ProviderRoutingExplainInput) => onExplain(input) })

  function run() {
    if (!jobId || !taskKey) return
    explain.mutate({ target_job_id: Number(jobId), task_key: taskKey })
  }

  return (
    <Surface padding="sm" variant="subtle" data-testid="routing-test-panel">
      <div className="space-y-3">
        <div className="flex items-center justify-between gap-2">
          <h3 className="text-sm font-medium text-text-primary">{t("provider_routing.test.title")}</h3>
          <Button onClick={onClose} size="sm" variant="secondary">
            {t("provider_routing.test.close")}
          </Button>
        </div>

        <Form.Field>
          <Form.Label>{t("provider_routing.test.job")}</Form.Label>
          <Form.Input
            onChange={(event) => setSearch(event.target.value)}
            placeholder={t("provider_routing.test.search_jobs")}
            type="search"
            value={search}
          />
        </Form.Field>
        <Select aria-label={t("provider_routing.test.job")} onChange={(event) => setJobId(event.target.value)} value={jobId}>
          <option value="">{t("provider_routing.test.pick_job")}</option>
          {(jobs.data?.jobs || []).map((job) => (
            <option key={job.id} value={job.id}>
              {`JOB-${job.id} ${job.title || job.issue_title}`}
            </option>
          ))}
        </Select>
        {jobs.isError ? <PanelMessage tone="error">{t("provider_routing.test.jobs_error")}</PanelMessage> : null}

        <Select aria-label={t("provider_routing.test.task")} onChange={(event) => setTaskKey(event.target.value)} value={taskKey}>
          {taskOptions.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </Select>

        <Button disabled={!jobId || !taskKey || explain.isPending} onClick={run} size="sm">
          {explain.isPending ? t("provider_routing.test.running") : t("provider_routing.test.run")}
        </Button>

        {explain.isError ? (
          <PanelMessage tone="error">{errorMessage(explain.error, t("provider_routing.test.error"))}</PanelMessage>
        ) : null}
        {explain.data ? <ExplanationResult explanation={explain.data} options={options} t={t} /> : null}
      </div>
    </Surface>
  )
}

function ExplanationResult({ explanation, options, t }: { explanation: ProviderRoutingExplanation; options: ProviderRoutingOptions; t: T }) {
  const rules = explanation.scope_precedence.flatMap((scope) => scope.rules)
  const winnerIndex = rules.findIndex((rule) => rule.winning)

  return (
    <div className="space-y-2" data-testid="routing-test-result">
      <p className="text-sm font-medium text-text-primary">{winnerLine(explanation, winnerIndex, options, t)}</p>
      {rules.length > 0 ? (
        <details>
          <summary className="cursor-pointer text-xs text-text-secondary">{t("provider_routing.test.rules", { count: rules.length })}</summary>
          <ul className="mt-2 space-y-2">
            {rules.map((rule, index) => (
              <li className="text-xs" key={rule.id}>
                <span className="text-text-primary">{t("provider_routing.test.rule_n", { n: index + 1 })}</span>
                <span className="text-text-secondary">{`: ${ruleReason(rule, options, t)}`}</span>
                <details className="mt-1">
                  <summary className="cursor-pointer text-text-secondary">{t("provider_routing.test.evidence")}</summary>
                  <pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words text-[11px] text-text-secondary">
                    {JSON.stringify(rule.evidence, null, 2)}
                  </pre>
                </details>
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </div>
  )
}

function providerLabel(options: ProviderRoutingOptions, provider: string) {
  return options.agent_providers?.find((entry) => entry.value === provider)?.label || provider
}

function winnerLine(explanation: ProviderRoutingExplanation, winnerIndex: number, options: ProviderRoutingOptions, t: T) {
  if (explanation.explicit_pin) {
    return t("provider_routing.test.pinned", { provider: providerLabel(options, explanation.explicit_pin.provider || "") })
  }
  const decision = explanation.winning_decision
  if (winnerIndex < 0) return t("provider_routing.test.no_winner")
  const n = winnerIndex + 1
  if (decision.decision?.status === "held") {
    return t("provider_routing.test.holds", { n, reason: decision.decision.reason || t("provider_routing.test.hold_no_reason") })
  }
  const providers = (decision.final_action?.candidates || []).map((candidate) => providerLabel(options, candidate.provider))
  return t("provider_routing.test.wins", { n, providers: providers.join(t("provider_routing.test.then")) })
}

function ruleReason(rule: ProviderRoutingRuleTrace, options: ProviderRoutingOptions, t: T) {
  switch (rule.outcome) {
    case "matched_winner":
      return t("provider_routing.test.matched")
    case "disabled_skipped":
      return t("provider_routing.test.disabled")
    case "not_evaluated_after_winner":
      return t("provider_routing.test.not_evaluated")
    case "overridden_by_explicit_pin":
      return t("provider_routing.test.overridden")
    default:
      return t("provider_routing.test.skipped", { reason: failureReason(rule.evidence, options, t) })
  }
}

function failureReason(evidence: ProviderRoutingRuleEvidence[], options: ProviderRoutingOptions, t: T) {
  const attempt = evidence.find((entry) => entry.trigger?.matched) || evidence[0]
  if (!attempt || attempt.trigger?.matched === false) return t("provider_routing.test.trigger_differs")

  const failed = Object.entries(attempt.conditions || {}).find(([, result]) => result.configured !== false && !result.matched)
  if (!failed) return t("provider_routing.test.condition_failed")
  const [key, result] = failed
  if (key === "usage") return usageFailure(result, options, t)
  return t("provider_routing.test.condition_not_met", { condition: t(`provider_routing.conditions.${key}`) })
}

function usageFailure(result: NonNullable<ProviderRoutingRuleEvidence["conditions"]>[string], options: ProviderRoutingOptions, t: T) {
  const expected = (result.expected || {}) as Record<string, unknown>
  const actual = (result.actual || {}) as Record<string, unknown>
  const label = providerLabel(options, String(actual.provider || expected.provider || ""))
  const comparator = Object.keys(COMPARATOR_SYMBOLS).find((key) => key in expected)
  if (comparator && typeof actual.remaining_percent === "number") {
    return t("provider_routing.test.usage_failed", {
      provider: label,
      actual: Math.round(actual.remaining_percent),
      symbol: COMPARATOR_SYMBOLS[comparator],
      expected: Math.round(Number(expected[comparator]))
    })
  }
  return t("provider_routing.test.condition_not_met", { condition: t("provider_routing.conditions.usage") })
}
