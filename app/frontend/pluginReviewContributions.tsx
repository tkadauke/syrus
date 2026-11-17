import { lazy, Suspense, type ComponentType, type ReactNode } from "react"
import "./builtInPluginContributions"
import { withPluginErrorBoundary } from "./components/PluginErrorBoundary"
import { getPluginContribution, pluginContributionLoader } from "./pluginContributionRegistry"

export type ReviewContributionKind = "target_editor" | "evidence" | "audit" | "settings_summary"
export type ReviewContributionProps = { payload: unknown; contribution: ReviewContribution; onChange?: (value: unknown) => void }
export type ReviewContribution = {
  key: string
  component: string
  kind: ReviewContributionKind
  target_type?: string | null
  artifact_type?: string | null
  trigger_kinds?: string[]
  target_required?: string[]
  label_key?: string | null
  description_key?: string | null
  aria_label_key?: string | null
}

type PluginModule = { default?: ComponentType<ReviewContributionProps> }
const cache = new Map<string, ComponentType<ReviewContributionProps>>()

export function reviewContributionComponentFor(key: string | null | undefined) {
  if (!key) return null
  if (cache.has(key)) return cache.get(key)!
  const [pluginName, componentKey] = key.split("/", 2)
  const contribution = getPluginContribution<PluginModule>("review_contribution", pluginName, componentKey)
  if (!contribution) return null
  const Component = lazy(async () => {
    const module = await pluginContributionLoader(contribution)()
    if (!module.default) throw new Error(`Plugin review contribution ${key} has no default export`)
    return { default: module.default }
  })
  const IsolatedComponent = withPluginErrorBoundary(pluginName, Component)
  cache.set(key, IsolatedComponent)
  return IsolatedComponent
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
