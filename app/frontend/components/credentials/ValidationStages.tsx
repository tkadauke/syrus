// Staged-validation list extracted from GeminiSetupSheet so every credential
// setup surface can render the same "checks cascade to green" experience.
// The data-testid/data-status contract (`<prefix>-validation-stages`,
// `<prefix>-stage-<key>`) is load-bearing: GeminiSetupSheet.test.tsx and the
// chat flow's tests assert against it.

export type StageStatus = "pending" | "running" | "ok" | "failed"

export type ValidationStage<K extends string = string> = {
  key: K
  status: StageStatus
  detail?: string
}

export function ValidationStages<K extends string>({
  stages,
  labels,
  testIdPrefix,
  className = "mt-4 space-y-2"
}: {
  stages: ValidationStage<K>[]
  labels: Record<K, string>
  testIdPrefix: string
  className?: string
}) {
  return (
    <ul className={className} data-testid={`${testIdPrefix}-validation-stages`}>
      {stages.map((stage) => (
        <li className="flex items-center gap-2 text-sm" data-status={stage.status} data-testid={`${testIdPrefix}-stage-${stage.key}`} key={stage.key}>
          <StageIcon status={stage.status} />
          <span
            className={
              stage.status === "failed"
                ? "text-red-700 dark:text-red-300"
                : stage.status === "ok"
                  ? "text-emerald-700 dark:text-emerald-300"
                  : "text-gray-600 dark:text-gray-300"
            }
          >
            {labels[stage.key]}
            {stage.detail ? <span className="ml-1 text-xs text-gray-400">({stage.detail})</span> : null}
          </span>
        </li>
      ))}
    </ul>
  )
}

export function StageIcon({ status }: { status: StageStatus }) {
  if (status === "running") {
    return (
      <span aria-hidden="true" className="inline-block h-4 w-4 animate-spin rounded-full border-2 border-brand border-t-transparent" />
    )
  }
  if (status === "ok") {
    return (
      <span aria-hidden="true" className="inline-flex h-4 w-4 items-center justify-center rounded-full bg-emerald-100 text-2xs font-bold text-emerald-700 dark:bg-emerald-900 dark:text-emerald-300">
        ✓
      </span>
    )
  }
  if (status === "failed") {
    return (
      <span aria-hidden="true" className="inline-flex h-4 w-4 items-center justify-center rounded-full bg-red-100 text-2xs font-bold text-red-700 dark:bg-red-900 dark:text-red-300">
        ✕
      </span>
    )
  }
  return <span aria-hidden="true" className="inline-block h-4 w-4 rounded-full border-2 border-gray-200 dark:border-gray-700" />
}
