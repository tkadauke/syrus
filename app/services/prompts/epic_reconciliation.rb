module Prompts
  # Prompt for the auto-created reconciliation Job inside an Epic.
  # The reconciliation Job runs after all sibling Jobs have been approved
  # and reviews the combined changes for cross-Job inconsistencies.
  # Branches on reconciliation_mode: "pr" (fix inline) or "feedback"
  # (submit targeted feedback to each Job that needs changes).
  class EpicReconciliation
    def initialize(epic:, jobs: [], reconciliation_mode: "pr")
      @epic = epic
      @jobs = jobs
      @reconciliation_mode = reconciliation_mode
    end

    def to_s
      [
        preamble,
        mode_instructions,
        GitSafety::TEXT,
        SubmitSummaryInstructions::TEXT
      ].compact_blank.join("\n\n")
    end

    private

    def preamble
      job_list = @jobs.map do |job|
        pr_ref = job.pr_number ? "PR ##{job.pr_number}" : "(not yet open)"
        "- #{job.slug}: #{job.title} — #{pr_ref}"
      end.join("\n")

      <<~TEXT.strip
        You are a reconciliation agent for the Epic "#{@epic.title}".

        The following Jobs have been implemented as part of this Epic:
        #{job_list}

        Your task: review the code changes introduced by these Jobs together and identify cross-Job inconsistencies — mismatched UI component styles, divergent naming conventions, duplicate abstractions, or conflicting API shapes.
      TEXT
    end

    def mode_instructions
      case @reconciliation_mode
      when "feedback"
        <<~TEXT.strip
          For each Job that needs changes, call submit_chat_feedback with the target JOB-{id} and a focused, actionable description of what to change.
          Once all feedback is submitted (or you determine none is needed), make no further code changes. This Job closes automatically.
        TEXT
      else
        <<~TEXT.strip
          If you find inconsistencies, fix them in a single focused commit. Touch only what is needed to make the Jobs consistent — do not refactor beyond that scope.
          If everything is already consistent, make no changes. Producing no changes closes this Job automatically.
        TEXT
      end
    end
  end
end
