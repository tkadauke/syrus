module Prompts
  # Prompt for feedback workflows after summarize_amend. The prior step's
  # submit_summary remains revision-scoped; this prompt refreshes canonical
  # Job/PR review metadata only when feedback changed the Job's effective intent.
  class RefreshJobMetadata
    def initialize(job:, current_pr: nil, prior_summaries: [], feedback: nil, diff: nil)
      @job = job
      @current_pr = current_pr
      @prior_summaries = prior_summaries || []
      @feedback = feedback
      @diff = diff
    end

    def to_s
      <<~PROMPT.strip
        Review whether the feedback workflow changed the Job's effective intent.

        Original Job title:
        #{@job.title}

        Original Job prompt/body:
        #{@job.issue_body}

        Current PR title:
        #{current_pr_title}

        Current PR body:
        #{current_pr_body}

        Feedback handled in this workflow:
        #{@feedback.presence || "(none recorded)"}

        Prior workflow summaries:
        #{prior_summary_text}

        Current diff:
        #{diff_text}

        If the feedback was narrow and does not change the top-level Job/PR
        review story, call `submit_job_metadata` with changed=false and a short
        intent_revision_reason.

        If the Job's effective intent changed, call `submit_job_metadata` with
        changed=true and provide:
        - title: the canonical current Job/PR title.
        - summary: 1-2 sentences for the Job detail header.
        - pr_body: concise markdown describing the whole current PR, without
          Syrus managed footers or generated attribution.
        - test_plan: actionable reviewer checks with steps and optional notes.
        - intent_revision_reason: why the canonical metadata changed.

        Do not edit files. Do not commit. Do not call `submit_summary`.
      PROMPT
    end

    private

    def current_pr_title
      @current_pr&.title.to_s.presence || "(no managed PR title available)"
    end

    def current_pr_body
      @current_pr&.body.to_s.presence || "(no managed PR body available)"
    end

    def prior_summary_text
      return "(none)" if @prior_summaries.empty?

      @prior_summaries.each_with_index.map { |summary, index| "Round #{index + 1}: #{summary}" }.join("\n")
    end

    def diff_text
      @diff.to_s.presence || "(no diff captured)"
    end
  end
end
