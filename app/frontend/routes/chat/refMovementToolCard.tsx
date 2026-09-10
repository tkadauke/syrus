import { isPlainObject } from "@app/pluginToolCards"
import { Badge, displayValue, Row, SectionLabel, StatePill } from "./toolCardUi"

// Shared core-field parsing/rendering for the ref-movement action record
// (the tool-card work), returned by both dispatch_ref_movement_action and
// read_ref_movement_status. Each tool additionally carries its own
// job/workflow linkage shape (ids only on dispatch; nested summaries on
// read_ref_movement_status), so the two tool_cards files stay separate and
// only share this core-fields block. Lives outside `tool_cards/` for the
// same reason as toolCardUi.tsx.
export type RefMovementCore = {
  actionId: string
  actionName: string
  state: string
  blockedReason: string | null
  sourceKind: string | null
  sourceRef: string | null
  targetKind: string | null
  targetRef: string | null
  targetRepository: string | null
  targetInferred: boolean
  mode: string | null
  gradePhases: string[]
}

function gradePhases(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((phase) => (typeof phase === "string" && phase ? [phase] : []))
}

export function parseRefMovementCore(value: unknown): RefMovementCore | null {
  if (!isPlainObject(value)) return null

  const actionId = displayValue(value.ref_movement_action_id)
  const actionName = displayValue(value.action_name)
  const state = displayValue(value.state)
  if (!actionId || !actionName || !state) return null

  return {
    actionId,
    actionName,
    state,
    blockedReason: displayValue(value.blocked_reason),
    sourceKind: displayValue(value.source_kind),
    sourceRef: displayValue(value.source_ref),
    targetKind: displayValue(value.target_kind),
    targetRef: displayValue(value.target_ref),
    targetRepository: displayValue(value.target_repository),
    targetInferred: value.target_inferred === true,
    mode: displayValue(value.mode),
    gradePhases: gradePhases(value.grade_phases)
  }
}

export function refMovementCollapsedSummary(core: RefMovementCore): string {
  const action = core.actionName.replace(/_/g, " ")
  if (core.state === "blocked") return `${action} blocked${core.blockedReason ? `: ${core.blockedReason}` : ""}`
  return `${action} (${core.state})`
}

export function RefMovementCoreFields({ core }: { core: RefMovementCore }) {
  return (
    <>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{core.actionName}</span>
        <StatePill state={core.state} />
        {core.mode ? <Badge>{core.mode}</Badge> : null}
      </div>
      {core.blockedReason ? (
        <div className="rounded bg-amber-100 px-2 py-1 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">{core.blockedReason}</div>
      ) : null}
      {core.sourceRef || core.targetRef ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {core.sourceRef ? <Row label={core.sourceKind ? `Source (${core.sourceKind})` : "Source"} value={core.sourceRef} /> : null}
          {core.targetRef ? (
            <Row
              label={`${core.targetKind ? `Target (${core.targetKind})` : "Target"}${core.targetRepository ? ` · ${core.targetRepository}` : ""}${core.targetInferred ? " · inferred" : ""}`}
              value={core.targetRef}
            />
          ) : null}
        </dl>
      ) : null}
      {core.gradePhases.length > 0 ? (
        <div>
          <SectionLabel>Grade phases</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {core.gradePhases.map((phase) => <Badge key={phase}>{phase}</Badge>)}
          </div>
        </div>
      ) : null}
    </>
  )
}
