export type ProposerAttributionValue = {
  label: string
  handle?: string | null
}

export function ProposerAttribution({
  label,
  proposer
}: {
  label: (values: { name: string; handle: string }) => string
  proposer: ProposerAttributionValue | null | undefined
}) {
  if (!proposer) return null

  return (
    <span className="text-xs text-text-muted" data-testid="proposer-attribution">
      {label({ name: proposer.label, handle: proposer.handle ? `@${proposer.handle}` : "" })}
    </span>
  )
}
