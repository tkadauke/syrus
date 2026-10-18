import { SlugHoverCard } from "./SlugHoverCard"
import { WorkflowReferenceControl } from "./WorkflowReferenceControl"

export function WorkflowReference({ slug, path, className = "" }: { slug: string; path: string; className?: string }) {
  const id = Number(slug.match(/^WF-(\d+)$/i)?.[1])
  const control = <WorkflowReferenceControl className={className} path={path} slug={slug} />

  if (!Number.isFinite(id)) return control

  return <SlugHoverCard href={path} id={id} kind="workflow">{control}</SlugHoverCard>
}
