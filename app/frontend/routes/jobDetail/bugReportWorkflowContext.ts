import type { JobDetailPayload, JobRun, JobStep, JobWorkflow } from "../../api/jobs"
import type { BugReportOptionalAttachment } from "../../lib/bugReportOptionalAttachments"
import { jobSlug } from "./formatting"

const WORKFLOW_CONTEXT_LIMIT = 3
const STEP_CONTEXT_LIMIT = 20
const RUN_CONTEXT_LIMIT = 3
const TEXT_FIELD_LIMIT = 500

export function jobWorkflowContextBugReportAttachment(payload: JobDetailPayload): BugReportOptionalAttachment | null {
  if (payload.workflows.length === 0) return null
  const count = Math.min(payload.workflows.length, WORKFLOW_CONTEXT_LIMIT)

  return {
    id: `job-${payload.job.id}-recent-workflows`,
    label: "Recent workflow context",
    description: `Attach the latest ${count} workflow${count === 1 ? "" : "s"} for this Job.`,
    preview: `${jobSlug(payload.job.id)} - ${payload.job.issue_title || "Untitled Job"}\n${payload.workflows.slice(0, count).map((workflow) => `${workflow.slug} ${workflow.trigger_kind} ${workflow.state}`).join("\n")}`,
    defaultChecked: false,
    buildFile: () => new File([serializeJobWorkflowContext(payload)], "job-workflows-context.txt", { type: "text/plain" })
  }
}

export function serializeJobWorkflowContext(payload: JobDetailPayload) {
  const lines: string[] = [
    `Job: ${jobSlug(payload.job.id)}`,
    `Title: ${payload.job.issue_title || "Untitled Job"}`,
    `State: ${payload.job.state}`,
    `Repository: ${payload.repository.slug}`,
    `Current URL: ${typeof window === "undefined" ? "" : window.location.href}`,
    `Included workflows: ${Math.min(payload.workflows.length, WORKFLOW_CONTEXT_LIMIT)} of ${payload.workflows.length}`,
    ""
  ]

  payload.workflows.slice(0, WORKFLOW_CONTEXT_LIMIT).forEach((workflow, index) => {
    appendWorkflow(lines, workflow, index + 1)
  })

  return `${lines.join("\n")}\n`
}

function appendWorkflow(lines: string[], workflow: JobWorkflow, ordinal: number) {
  lines.push(
    `Workflow ${ordinal}: ${workflow.slug}`,
    `  ID: ${workflow.id}`,
    `  Trigger: ${workflow.trigger_kind}`,
    `  State: ${workflow.state}`,
    `  Provider: ${workflow.agent_provider || "none"}`,
    `  Created: ${workflow.created_at || "unknown"}`,
    `  Started: ${workflow.started_at || "unknown"}`,
    `  Finished: ${workflow.finished_at || "unknown"}`
  )

  if (workflow.steps.length === 0) {
    lines.push("  Steps: none", "")
    return
  }

  lines.push("  Steps:")
  workflow.steps.slice(0, STEP_CONTEXT_LIMIT).forEach((step) => appendStep(lines, step))
  if (workflow.steps.length > STEP_CONTEXT_LIMIT) {
    lines.push(`    ... ${workflow.steps.length - STEP_CONTEXT_LIMIT} more step${workflow.steps.length - STEP_CONTEXT_LIMIT === 1 ? "" : "s"} omitted`)
  }
  lines.push("")
}

function appendStep(lines: string[], step: JobStep) {
  lines.push(
    `    - ${step.display_name || step.kind}`,
    `      Kind: ${step.kind}`,
    `      Display status: ${step.display_status || "unknown"}`,
    `      State: ${step.state}`
  )

  if (step.runs.length === 0) {
    lines.push("      Runs: none")
    return
  }

  lines.push("      Runs:")
  step.runs.slice(0, RUN_CONTEXT_LIMIT).forEach((run) => appendRun(lines, run))
  if (step.runs.length > RUN_CONTEXT_LIMIT) {
    lines.push(`        ... ${step.runs.length - RUN_CONTEXT_LIMIT} more run${step.runs.length - RUN_CONTEXT_LIMIT === 1 ? "" : "s"} omitted`)
  }
}

function appendRun(lines: string[], run: JobRun) {
  lines.push(
    `        - Run ${run.id}`,
    `          State: ${run.state}`,
    `          Provider: ${run.agent_provider || "none"}`,
    `          Outcome: ${run.agent_outcome || "unknown"}`,
    `          Head SHA: ${run.head_sha || "unknown"}`
  )

  if (run.agent_pr_title) lines.push(`          PR title: ${truncate(run.agent_pr_title)}`)
  if (run.agent_summary) lines.push(`          Summary: ${truncate(run.agent_summary)}`)
}

function truncate(value: string) {
  if (value.length <= TEXT_FIELD_LIMIT) return value
  return `${value.slice(0, TEXT_FIELD_LIMIT)}...`
}
