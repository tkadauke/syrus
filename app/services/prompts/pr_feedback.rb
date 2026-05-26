module Prompts
  # Prompt for follow-up Runs triggered by PR review comments.
  #
  # `comments` is the FULL chronological comment list on the PR
  # (issue_comments + review_comments). Each is rendered with a
  # "[NEW]" tag when it was created after `cutoff`, so the agent
  # can tell which feedback is actionable this round vs. background
  # context from prior rounds it already addressed.
  #
  # `prior_summaries` is an array of summary strings produced by
  # previous pr_comment workflows on this Job (oldest first). They
  # give the agent visibility into "what you concluded last time" so
  # it doesn't revert prior addressed feedback by accident.
  #
  # `recent_commits` is an array of `{sha:, subject:, body:}` hashes
  # for the most recent commits on the working branch. The agent
  # can cross-reference what actually shipped against what was
  # promised in the prior summaries.
  class PrFeedback
    def initialize(issue:, comments:, cutoff: nil, prior_summaries: [], recent_commits: [])
      @issue = issue
      @comments = comments
      @cutoff = cutoff
      @prior_summaries = prior_summaries || []
      @recent_commits = recent_commits || []
    end

    def to_s
      sections = [
        issue_section,
        prior_context_section,
        comments_section,
        commits_section,
        directives_section
      ].compact

      body = sections.join("\n\n---\n\n")
      [ body, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def issue_section
      <<~SECTION.strip
        Original issue: #{@issue.title}

        #{@issue.body}
      SECTION
    end

    def prior_context_section
      return nil if @prior_summaries.empty?

      lines = @prior_summaries.each_with_index.map do |summary, index|
        "Round #{index + 1}:\n#{summary}"
      end

      <<~SECTION.strip
        What you've done on this PR in previous review rounds:

        #{lines.join("\n\n")}
      SECTION
    end

    def comments_section
      new_count = new_comment_count

      header = if new_count.positive? && new_count < @comments.size
        "PR review thread (#{@comments.size} comments total, #{new_count} new since you last addressed feedback):"
      elsif new_count.positive?
        "PR review thread (#{new_count} new comments — first review round):"
      else
        "PR review thread (#{@comments.size} comments):"
      end

      <<~SECTION.strip
        #{header}

        #{render_blocks}
      SECTION
    end

    def commits_section
      return nil if @recent_commits.empty?

      lines = @recent_commits.map do |c|
        sha = c[:sha] || c["sha"]
        subject = c[:subject] || c["subject"]
        "- #{sha.to_s[0, 7]} #{subject}"
      end

      <<~SECTION.strip
        Recent commits on the working branch (newest first):

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      # Single-line sentences here so include("Make commits to the current branch.")
      # type assertions stay easy — line-wrapping the directive
      # silently breaks downstream substring matches.
      lines = [
        "Address each piece of feedback marked [NEW].",
        "Prior comments are shown for context — you have already responded to those in earlier rounds.",
        "Do NOT revert your earlier work unless the [NEW] feedback explicitly asks for it.",
        "Make commits to the current branch."
      ]
      lines.join("\n")
    end

    def render_blocks
      @comments.map { |c| render(c) }.join("\n\n")
    end

    def render(comment)
      prefix = new_comment?(comment) ? "[NEW] " : ""
      body = inline?(comment) ? render_inline(comment) : render_conversation(comment)
      "#{prefix}#{body}"
    end

    def new_comment?(comment)
      return true if @cutoff.nil?

      created_at = comment.respond_to?(:created_at) ? comment.created_at : nil
      created_at.present? && created_at > @cutoff
    end

    def new_comment_count
      @comments.count { |c| new_comment?(c) }
    end

    def inline?(comment)
      comment.respond_to?(:path) && comment.path.present?
    end

    def render_inline(comment)
      <<~BLOCK.strip
        [Inline comment from @#{comment.user.login} on #{comment.path}:#{comment.line}]
        Context:
        #{indent(comment.diff_hunk.to_s)}

        Comment:
        #{comment.body}
      BLOCK
    end

    def render_conversation(comment)
      "[Conversation comment from @#{comment.user.login} at #{comment.created_at}]\n#{comment.body}"
    end

    def indent(text, by: 2)
      pad = " " * by
      text.lines.map { |l| pad + l }.join.chomp + "\n"
    end
  end
end
