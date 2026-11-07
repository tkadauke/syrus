import { lazy, Suspense, type ComponentType, type ReactNode } from "react"

export type ReviewContributionKind = "target_editor" | "evidence" | "audit" | "settings_summary"
export type ReviewContributionProps = { payload: unknown; contribution: ReviewContribution; onChange?: (value: unknown) => void }
export type ReviewContribution = {
  key: string
  component: string
  kind: ReviewContributionKind
  target_type?: string | null
  artifact_type?: string | null
  label_key?: string | null
  description_key?: string | null
  aria_label_key?: string | null
}

type PluginModule = { default?: ComponentType<ReviewContributionProps> }
const modules = import.meta.glob<PluginModule>([
  "../../plugins/*/app/frontend/review_contributions/*.tsx",
  "!../../plugins/*/app/frontend/review_contributions/*.test.tsx"
])
const pathPattern = /^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/review_contributions\/([^/.]+)\.tsx$/
const loaders = Object.fromEntries(
  Object.entries(modules).flatMap(([path, loader]) => {
    const match = path.match(pathPattern)
    return match ? [[`${match[1]}/${match[2]}`, loader]] : []
  })
) as Record<string, () => Promise<PluginModule>>
const cache = new Map<string, ComponentType<ReviewContributionProps>>()

export function reviewContributionComponentFor(key: string | null | undefined) {
  if (!key || !loaders[key]) return null
  if (cache.has(key)) return cache.get(key)!
  const Component = lazy(async () => {
    const module = await loaders[key]()
    if (!module.default) throw new Error(`Plugin review contribution ${key} has no default export`)
    return { default: module.default }
  })
  cache.set(key, Component)
  return Component
}

export function renderReviewContribution(contribution: ReviewContribution, payload: unknown, fallback: ReactNode = null, onChange?: (value: unknown) => void) {
  const Component = reviewContributionComponentFor(contribution.component)
  if (!Component) return fallback
  return (
    <Suspense fallback={fallback}>
      <Component contribution={contribution} onChange={onChange} payload={payload} />
    </Suspense>
  )
}

export function matchingReviewContribution(
  contributions: ReviewContribution[],
  kind: ReviewContributionKind,
  discriminator: { targetType?: string; artifactType?: string } = {}
) {
  return contributions.find(
    (entry) =>
      entry.kind === kind &&
      (!discriminator.targetType || entry.target_type === discriminator.targetType) &&
      (!discriminator.artifactType || entry.artifact_type === discriminator.artifactType)
  )
}
