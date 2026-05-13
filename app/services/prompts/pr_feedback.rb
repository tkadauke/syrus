module Prompts
  # Prompt for follow-up Runs triggered by PR review comments. `comments`
  # is a chronologically-sorted array containing a mix of GitHub
  # issue_comments (no `path` attr) and review_comments (have `path`,
  # `line`, `diff_hunk`). The composer formats each kind so the agent
  # can tell where the feedback is anchored.
  class PrFeedback
    def initialize(issue:, comments:)
      @issue = issue
      @comments = comments
    end

    def to_s
      body = <<~PROMPT.strip
        Original issue: #{@issue.title}

        #{@issue.body}

        ---

        Reviewer feedback received since the last commit:

        #{render_blocks}

        ---

        Address each piece of feedback. Make commits to the current branch.
      PROMPT

      [ body, OperatorClarificationInstructions::TEXT, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def render_blocks
      @comments.map { |c| render(c) }.join("\n\n")
    end

    def render(comment)
      if inline?(comment)
        render_inline(comment)
      else
        render_conversation(comment)
      end
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
