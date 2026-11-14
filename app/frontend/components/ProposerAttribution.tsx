export type ProposerAttributionValue = {
  label: string
  handle?: string | null
}

export function ProposerAttribution({
  label,
  proposer,
  testId = "proposer-attribution"
}: {
  label: (values: { name: string; handle: string }) => string
  proposer: ProposerAttributionValue | null | undefined
  testId?: string
}) {
  if (!proposer) return null

  return (
    <span className="text-xs text-text-muted" data-testid={testId}>
      {label({ name: proposer.label, handle: proposer.handle ? `@${proposer.handle}` : "" })}
    </span>
  )
}
