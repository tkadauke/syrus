import { StatusPill } from "./StatusPill"

// Lives outside routes/jobDetail/components.tsx so the PR hover card on the
// dashboard can use it without pulling the job-detail and chat transcript
// modules into the startup bundle.
export function MergeablePill({ value }: { value: boolean | null }) {
  if (value === true) return <StatusPill state="mergeable" />
  if (value === false) return <StatusPill state="unmergeable" />
  return <StatusPill state="unknown" />
}
