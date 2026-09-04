module Prompts
  # Prompt for follow-up Runs triggered from Syrus Chat operator feedback.
  class ChatFeedback
    def initialize(issue:, feedback:, diff_comments: [], prior_summaries: [], recent_commits: [], epic: nil, job: nil, injected_context: [])
      @issue = issue
      @feedback = feedback
      @diff_comments = Array(diff_comments)
      @prior_summaries = prior_summaries || []
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
      @injected_context = Array(injected_context).compact
    end

    def to_s
      sections = [
        issue_section,
        epic_context,
        prior_context_section,
        feedback_section,
        diff_comments_section,
        commits_section,
        directives_section,
        injected_context_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT, ShellCommandExecutionContract::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
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

    def diff_comments_section
      return nil if @diff_comments.empty?

      <<~SECTION.strip
        Anchored diff comments:

        #{render_diff_comments}
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
        "Treat anchored diff comments as precise code-review feedback tied to the listed file and line.",
        "Do NOT broaden the work beyond the requested feedback.",
        "Do NOT revert earlier work unless the feedback explicitly asks for it.",
        "Make commits to the current branch."
      ].join("\n")
    end

    def injected_context_section
      return nil if @injected_context.empty?

      @injected_context.join("\n\n")
    end

    def render_diff_comments
      @diff_comments.map { |comment| render_diff_comment(comment.to_h) }.join("\n\n")
    end

    def render_diff_comment(comment)
      side = value(comment, "side")
      line = value(comment, "line").presence || (side == "left" ? value(comment, "old_line") : value(comment, "new_line"))
      refs = [ value(comment, "base_ref").presence, value(comment, "head_ref").presence ].compact.join("...")
      refs = "Refs: #{refs}\n" if refs.present?

      <<~COMMENT.strip
        [#{value(comment, "path")}:#{line} #{side}]
        #{refs}Context:
        #{indent(value(comment, "diff_hunk").to_s.presence || "(no hunk snapshot)")}

        Comment:
        #{value(comment, "body")}
      COMMENT
    end

    def value(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def indent(text, by: 2)
      pad = " " * by
      text.lines.map { |line| pad + line }.join.chomp + "\n"
    end
  end
end
