import { useState } from "react"
import { Button } from "../../components/Button"
import { Section } from "../../components/ui"
import { useT } from "../../hooks/useT"
import type { JobDetailPayload, JobRecoveryDecision } from "../../api/jobs"
import { useJobCommand } from "./command"
import { RetryFeedbackDialog } from "./JobHeader"

const ACTION_KEYS: Record<JobRecoveryDecision["recommended_action"], string> = {
  rerun_unchanged: "recovery_action_rerun",
  resume: "recovery_action_resume",
  repair_with_guidance: "recovery_action_repair",
  fresh_implementation: "recovery_action_restart_implementation",
  restart: "recovery_action_restart_implementation"
}

export function RecoveryCard({ command, payload }: { command: ReturnType<typeof useJobCommand>; payload: JobDetailPayload }) {
  const { t } = useT("jobs")
  const [dialogOpen, setDialogOpen] = useState(false)
  const decision = payload.actions.recovery_decision
  if (!decision || !["failed", "blocked", "cancelled"].includes(payload.job.state)) return null
  const action = decision.mode === "failed_step" ? payload.actions.retry_failed_step_action : payload.actions.retry_implementation_action
  const failures = decision.evidence.measured_failure_identities ?? []
  const inconclusive = inconclusiveFailures(decision)
  const timeline = payload.actions.recovery_timeline ?? []
  const required = decision.kind === "grader_loop_no_progress"
  const prefill = [decision.guidance, failures.length ? t("recovery_guidance_failures", { failures: failures.join(", ") }) : null].filter(Boolean).join("\n\n")
  const actionLabel = t(ACTION_KEYS[decision.recommended_action])

  return (
    <Section.Root className="border-l-4 border-l-warning-border" data-testid="job-recovery-card">
      <div className="flex flex-col gap-4">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-warning-text">{t("recovery_eyebrow")}</p>
          <h2 className="mt-1 text-lg font-semibold text-text-primary">{t(`recovery_title_${decision.kind}`)}</h2>
          <p className="mt-2 text-sm text-text-secondary">{decision.explanation}</p>
        </div>
        {failures.length ? <EvidenceList label={t("recovery_measured_failures")} values={failures} /> : null}
        {inconclusive.length ? <EvidenceList label={t("recovery_excluded_failures")} values={inconclusive} /> : null}
        <div>
          <h3 className="text-sm font-semibold text-text-primary">{t("recovery_attempt_timeline")}</h3>
          <ol className="mt-2 space-y-2 border-l border-border pl-4 text-sm">
            <li className="text-text-secondary">{t("recovery_original_execution", { workflow: decision.evidence.source_workflow_id ?? "—" })}</li>
            {timeline.map((item) => (
              <li key={item.id}>
                <span className="font-medium text-text-primary">{item.action.replaceAll("_", " ")}</span>
                <span className="text-text-secondary">
                  {" "}
                  · {item.actor} · {item.origin.replaceAll("_", " ")}
                </span>
                {item.resulting_revision ? <code className="ml-2 text-xs">{item.resulting_revision.slice(0, 8)}</code> : null}
                {item.reason || item.guidance ? <p className="mt-0.5 text-xs text-text-muted">{item.reason || item.guidance}</p> : null}
              </li>
            ))}
            <li className="font-medium text-text-primary">{t("recovery_terminal_decision", { decision: t(`recovery_title_${decision.kind}`) })}</li>
          </ol>
        </div>
        <div className="flex flex-col gap-2 border-t border-border pt-3 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm font-medium text-text-primary">{t("recovery_next_step", { action: actionLabel })}</p>
          <Button disabled={!action || command.isPending} onClick={() => setDialogOpen(true)} variant="primary">
            {actionLabel}
          </Button>
        </div>
        {!action ? (
          <p className="text-xs text-text-muted">{t(payload.actions.can_write ? "recovery_action_unavailable" : "recovery_action_permission_disabled")}</p>
        ) : null}
        <details className="text-xs text-text-muted">
          <summary className="cursor-pointer">{t("recovery_execution_details")}</summary>
          <div className="mt-2 space-y-1">
            {decision.evidence.source_workflow_id ? <p>Workflow {decision.evidence.source_workflow_id}</p> : null}
            {decision.evidence.source_revision ? <p>{t("recovery_revision", { revision: decision.evidence.source_revision })}</p> : null}
            {decision.evidence.failure_classification ? <p>{decision.evidence.failure_classification}</p> : null}
          </div>
        </details>
      </div>
      {dialogOpen && action ? (
        <RetryFeedbackDialog
          command={command}
          initialFeedback={prefill}
          input={{ method: "post", path: action.path }}
          onClose={() => setDialogOpen(false)}
          payload={payload}
          required={required}
          submitLabel={actionLabel}
        />
      ) : null}
    </Section.Root>
  )
}

function EvidenceList({ label, values }: { label: string; values: string[] }) {
  return (
    <div>
      <h3 className="text-sm font-semibold text-text-primary">{label}</h3>
      <ul className="mt-1 list-disc space-y-1 pl-5 text-sm text-text-secondary">
        {values.map((value) => (
          <li className="break-words" key={value}>
            {value.replace("\0", " — ")}
          </li>
        ))}
      </ul>
    </div>
  )
}

function inconclusiveFailures(decision: JobRecoveryDecision) {
  return (decision.evidence.rounds ?? [])
    .flatMap((round) => (Array.isArray(round.grader_results) ? round.grader_results : []))
    .filter((result): result is Record<string, unknown> => Boolean(result && typeof result === "object"))
    .filter((result) => result.classification === "infrastructure" || result.measured === false)
    .map((result) => String(result.name || result.identity || "Infrastructure execution failure"))
}
