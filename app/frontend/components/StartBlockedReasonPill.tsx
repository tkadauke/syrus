import { useT } from "../hooks/useT"
import { TonePill } from "./StatusPill"

type StartBlockedReason =
  | "dependency_failed"
  | "stack_dependencies_not_ready"
  | "stack_fan_in_base_unavailable"
  | "job_not_ready_for_execution"
  | "main_branch_broken"
  | "urgent_job_active"

const TONES: Record<StartBlockedReason, "amber" | "red" | "gray"> = {
  dependency_failed: "red",
  stack_dependencies_not_ready: "amber",
  stack_fan_in_base_unavailable: "amber",
  job_not_ready_for_execution: "amber",
  main_branch_broken: "red",
  urgent_job_active: "gray"
}

export function StartBlockedReasonPill({ reason }: { reason: string }) {
  const { t } = useT()
  const tone = TONES[reason as StartBlockedReason] ?? "amber"

  return (
    <TonePill
      tone={tone}
      title={t(`common:start_blocked_reason_tooltips.${reason}`, { defaultValue: "" })}
    >
      {t(`common:start_blocked_reasons.${reason}`, { defaultValue: reason })}
    </TonePill>
  )
}
