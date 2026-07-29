module Prompts
  # Prompt for the auto-created reconciliation Job inside an Epic.
  # The reconciliation Job runs after all sibling Jobs have been approved
  # and reviews/synthesizes the combined changes for consistency — catching
  # inter-Job conflicts, shared-surface regressions, and cross-cutting
  # concerns that individual reviewers may not have flagged.
  class EpicReconciliation
    def initialize(epic:)
      @epic = epic
    end

    def to_s
      <<~PROMPT.strip
        ## Epic reconciliation review

        You are performing a reconciliation review for the Epic **#{@epic.slug}: #{@epic.title}**.

        All sibling Jobs in this Epic have been implemented and approved individually.
        Your task is to review the combined changes across sibling Jobs for:

        - **Inter-Job consistency**: naming, API contracts, data shapes, and conventions that
          must be consistent across Jobs are actually consistent.
        - **Shared-surface regressions**: tests, migrations, routes, or configuration files
          touched by multiple Jobs that could conflict or regress each other.
        - **Cross-cutting concerns**: authentication, authorization, logging, error handling, or
          observability patterns that span multiple Jobs and must be applied uniformly.
        - **Integration gaps**: interactions between sibling Jobs that each Job's individual
          review could not catch (e.g., Job A adds an API endpoint, Job B calls it — verify
          the contract matches).

        If everything is consistent and no issues are found, call `submit_summary` with a
        brief note confirming the review passed. If issues are found, open a PR that
        addresses them. Do not re-implement or redo the work in the sibling Jobs —
        only add what is necessary to reconcile or repair cross-cutting issues.

        #{GitSafety::TEXT}

        #{SubmitSummaryInstructions::TEXT}
      PROMPT
    end
  end
end
