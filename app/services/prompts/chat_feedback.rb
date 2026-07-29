module Prompts
  # Prompt for follow-up Runs triggered from Syrus Chat operator feedback.
  class ChatFeedback
    def initialize(issue:, feedback:, prior_summaries: [], recent_commits: [], epic: nil, job: nil)
      @issue = issue
      @feedback = feedback
      @prior_summaries = prior_summaries || []
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
    end

    def to_s
      sections = [
        issue_section,
        epic_context,
        prior_context_section,
        feedback_section,
        commits_section,
        directives_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def issue_section
      <<~SECTION.strip
        Original issue: #{@issue.title}

        #{@issue.body}
      SECTION
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s.presence
    end

    def prior_context_section
      return nil if @prior_summaries.empty?

      lines = @prior_summaries.each_with_index.map do |summary, index|
        "Round #{index + 1}:\n#{summary}"
      end

      <<~SECTION.strip
        What you've done on this PR in previous feedback rounds:

        #{lines.join("\n\n")}
      SECTION
    end

    def feedback_section
      <<~SECTION.strip
        Operator feedback from Syrus Chat:

        #{@feedback}
      SECTION
    end

    def commits_section
      return nil if @recent_commits.empty?

      lines = @recent_commits.map do |commit|
        sha = commit[:sha] || commit["sha"]
        subject = commit[:subject] || commit["subject"]
        "- #{sha.to_s[0, 7]} #{subject}"
      end

      <<~SECTION.strip
        Recent commits on the working branch (newest first):

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      [
        "Address the operator feedback from Syrus Chat.",
        "Do NOT broaden the work beyond the requested feedback.",
        "Do NOT revert earlier work unless the feedback explicitly asks for it.",
        "Make commits to the current branch."
      ].join("\n")
    end
  end
end
