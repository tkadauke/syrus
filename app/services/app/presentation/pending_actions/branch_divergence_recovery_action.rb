module App
  module Presentation
    module PendingActions
      # Branch-divergence recovery actions: same "<verb> for <job>" label
      # shape and identical evidence-diff detail rendering.
      class BranchDivergenceRecoveryAction < Base
        LABELS = {
          "adopt_current_pr_head" => "Adopt current PR head for %s",
          "replace_pr_branch_with_workflow_output" => "Replace PR branch for %s",
          "retry_from_current_pr_branch" => "Retry from current PR branch for %s"
        }.freeze

        action_key(*LABELS.keys)

        def label
          format(LABELS.fetch(key), job_slug)
        end

        def detail
          evidence = payload["evidence"].to_h
          [
            "Remote SHA: #{evidence['remote_sha'].presence || 'unknown'}",
            "Workflow local SHA: #{evidence['workflow_local_sha'].presence || 'unknown'}",
            "Base SHA: #{evidence['base_sha'].presence || 'unknown'}",
            Array(evidence.dig("diff_summary", "files")).presence&.then { |files| "Changed files: #{files.first(10).join(', ')}" }
          ].compact.join("\n")
        end
      end
    end
  end
end
