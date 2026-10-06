import { lazy, Suspense, type ComponentType, type ReactNode } from "react"
import type { DiffReviewAnnotation, DiffReviewAnnotationAction, DiffReviewAnnotationPanel } from "./api/jobs"
import { Button, buttonClasses } from "./components/Button"
import { useT } from "./hooks/useT"
import { Markdown } from "./lib/Markdown"

export type PluginReviewAnnotationComponentProps = {
  item: DiffReviewAnnotation | DiffReviewAnnotationPanel | DiffReviewAnnotationAction
}

type PluginModule = {
  default?: ComponentType<PluginReviewAnnotationComponentProps>
}

const annotationModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/review_annotations/*.tsx")

export const pluginReviewAnnotationComponentKeys = Object.keys(annotationModules)
  .map((path) => path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/review_annotations\/([^/.]+)\.tsx$/))
  .filter((match): match is RegExpMatchArray => Boolean(match))
  .map((match) => `${match[1]}/${match[2]}`)

const componentLoaders = Object.fromEntries(
  Object.entries(annotationModules)
    .map(([path, loader]) => {
      const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/review_annotations\/([^/.]+)\.tsx$/)
      if (!match) return []

      return [`${match[1]}/${match[2]}`, loader]
    })
    .filter((entry): entry is [string, () => Promise<PluginModule>] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType<PluginReviewAnnotationComponentProps>>()

export function pluginReviewAnnotationComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin review annotation component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}

export function renderPluginReviewAnnotation(item: DiffReviewAnnotation | DiffReviewAnnotationPanel | DiffReviewAnnotationAction, fallback: ReactNode) {
  const Component = pluginReviewAnnotationComponentFor(item.component)
  if (!Component) return fallback

  return (
    <Suspense fallback={fallback}>
      <Component item={item} />
    </Suspense>
  )
}

export function ReviewAnnotationCard({ item }: { item: DiffReviewAnnotation | DiffReviewAnnotationPanel }) {
  const { t } = useT("jobs")
  const title = item.title || t("review_annotation_default_title")
  const body = item.body
  const fallback = (
    <div className={`rounded border p-3 text-sm ${annotationToneClass(item.tone)}`}>
      <div className="font-medium">{title}</div>
      {body ? <Markdown className="mt-1 text-text-secondary" text={body} /> : null}
      {"actions" in item && item.actions?.length ? (
        <div className="mt-2 flex flex-wrap gap-2">
          {item.actions.map((action, index) => (
            <ReviewAnnotationActionButton action={action} key={String(action.id ?? index)} />
          ))}
        </div>
      ) : null}
    </div>
  )

  return renderPluginReviewAnnotation(item, fallback)
}

export function ReviewAnnotationActionButton({ action }: { action: DiffReviewAnnotationAction }) {
  const { t } = useT("jobs")
  const label = action.label || t("review_annotation_default_action")
  const fallback = action.href ? (
    <a className={buttonClasses("secondary", "sm")} href={action.href}>
      {label}
    </a>
  ) : (
    <Button disabled size="sm" variant="secondary">
      {label}
    </Button>
  )

  return renderPluginReviewAnnotation(action, fallback)
}

function annotationToneClass(tone: string | null | undefined) {
  if (tone === "danger") return "border-danger-border bg-danger-bg text-danger-text"
  if (tone === "warning") return "border-warning-border bg-warning-bg text-warning-text"
  if (tone === "success") return "border-success-border bg-success-bg text-success-text"
  if (tone === "info") return "border-info-border bg-info-bg text-info-text"
  return "border-border bg-surface text-text-primary"
}
