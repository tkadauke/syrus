// Proposal editing/display types + helpers extracted from Chat.tsx.
//
// The editable-proposal view model and dependency pill type used by the
// proposal edit modal and dependency picker, plus the pure helpers that seed
// the initial dependency pills, adapt a child proposal into the editable
// shape, and pick the confirm-button label. Lifting the types here lets the
// proposal components move out of the 6k-line Chat.tsx next.
import type { ChatProposal, ChatProposalChild, ChatProposalDependency } from "../../api/chats"

export type EditableProposal = Pick<ChatProposal, "id" | "title" | "slug" | "body" | "proposed" | "epic_bundle" | "app_update_path"> & {
  dependency_slugs?: string[]
  dependencies?: ChatProposalDependency[]
  depends_on_job_ids?: number[]
  depends_on_epic_ids?: number[]
  nonlinear_dependency_override?: boolean
}

export type DependencyPill = {
  key: string
  label: string
  detail?: string
}

export function initialProposalDependencyPills(proposal: EditableProposal) {
  const details = new Map((proposal.dependencies || []).map((dependency) => [dependency.slug, dependency.title]))
  return (proposal.dependency_slugs || []).map((slug) => ({ key: slug, label: slug, detail: details.get(slug) }))
}

export function editableChildProposal(child: ChatProposalChild): EditableProposal {
  return {
    id: child.id,
    title: child.title,
    slug: child.slug,
    body: child.body,
    proposed: child.proposed,
    epic_bundle: false,
    app_update_path: child.app_update_path,
    dependency_slugs: child.dependencies,
    dependencies: (child.dependency_details || []).map((dependency) => ({
      slug: dependency.slug,
      title: dependency.title,
      state: "",
      confirmed: dependency.confirmed,
      materialized_label: dependency.materialized_label,
      materialized_path: dependency.materialized_path
    })),
    depends_on_job_ids: child.depends_on_job_ids || [],
    depends_on_epic_ids: child.depends_on_epic_ids || [],
    nonlinear_dependency_override: false
  }
}

export function proposalConfirmLabel(proposal: ChatProposal, childJobCount: number) {
  if (!proposal.epic_bundle) return "Confirm"

  return "Backlog"
}

export function proposalConfirmAriaLabel(proposal: ChatProposal, childJobCount: number) {
  if (!proposal.epic_bundle) return "Confirm"

  return childJobCount > 0 ? "Confirm Epic and Jobs" : "Confirm Epic"
}
