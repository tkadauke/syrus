module App
  module Presentation
    module PendingActions
      # Job-scoped controls whose label is a fixed "<verb> <job slug>"
      # with no detail line.
      class JobScopedAction < Base
        LABELS = {
          "cancel_job" => "Cancel %s",
          "retry_job" => "Retry %s",
          "force_fail_job" => "Force fail %s",
          "rebase_job" => "Rebase %s",
          "force_rebase" => "Force rebase %s",
          "reopen_job" => "Reopen %s",
          "approve_job" => "Approve %s",
          "unapprove_job" => "Unapprove %s",
          "poll_job_feedback" => "Poll PR feedback for %s",
          "run_visual_review" => "Run visual review for %s",
          "check_job_mergeability" => "Check mergeability for %s",
          "force_landing_recheck" => "Force landing recheck for %s",
          "manual_agentic_run" => "Manual agentic run for %s"
        }.freeze

        action_key(*LABELS.keys)

        def label
          format(LABELS.fetch(key), job_slug)
        end
      end
    end
  end
end
