import { useQuery } from "@tanstack/react-query"
import { useNavigate } from "react-router-dom"
import { fetchWorkflowPreview } from "../api/workflows"
import { Card, Skeleton } from "./Card"
import { StatusPill } from "./StatusPill"
import { WorkflowReference } from "./WorkflowReference"

export function WorkflowPreviewCard({ id }: { id: number; slug?: string; compact?: boolean }) {
  const navigate = useNavigate()
  const { data, isPending } = useQuery({
    queryKey: ["workflow-preview", id],
    queryFn: ({ signal }) => fetchWorkflowPreview(id, signal),
    staleTime: 30_000
  })
  const workflow = data?.workflow

  if (!workflow && isPending) return <WorkflowPreviewSkeleton />
  if (!workflow) return null

  const open = () => navigate(workflow.path)
  return (
    <Card
      aria-label={`${workflow.slug} ${workflow.trigger_label}`}
      className="cursor-pointer"
      onClick={open}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return
        if (event.key !== "Enter" && event.key !== " ") return
        event.preventDefault()
        open()
      }}
      role="link"
      tabIndex={0}
      variant="preview"
    >
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <WorkflowReference path={workflow.path} slug={workflow.slug} />
        <span className="text-xs text-text-secondary">{workflow.trigger_label}</span>
        <StatusPill state={workflow.state} />
      </div>
      <ol className="space-y-1.5">
        {workflow.steps.map((step, index) => step.ellipsis ? (
          <li aria-hidden="true" className="border-t border-dashed border-border text-center text-xs text-text-secondary" key={`ellipsis-${index}`}><span className="relative -top-2 bg-surface px-2">…</span></li>
        ) : (
          <li className="flex items-center justify-between gap-3 text-xs" key={step.id}>
            <span className="min-w-0 truncate text-text-primary">{step.display_name}</span>
            {step.status ? <StatusPill state={step.status} /> : null}
          </li>
        ))}
      </ol>
    </Card>
  )
}

function WorkflowPreviewSkeleton() {
  return <Card variant="preview"><div className="space-y-2"><Skeleton className="h-4 w-40" /><Skeleton className="h-3 w-full" /><Skeleton className="h-3 w-3/4" /></div></Card>
}
