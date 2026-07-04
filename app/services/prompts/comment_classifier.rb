module Prompts
  class CommentClassifier
    MAX_BODY_LENGTH = 2_000

    def initialize(body:)
      @body = body.to_s.safe_byteslice(0, MAX_BODY_LENGTH)
    end

    def to_s
      <<~PROMPT
        You are classifying a GitHub pull request comment.

        Determine whether this comment contains actionable feedback: a request for a code change, correction, or improvement that a developer should act on.

        Actionable feedback includes:
        - Requesting a code change, refactor, or fix
        - Pointing out a bug, error, or edge case that needs addressing
        - Asking for additional functionality or tests to be added
        - Asking clarifying questions about the implementation that imply changes are needed

        Non-actionable comments include:
        - Approval or praise ("LGTM", "nice work", "looks good")
        - General discussion or questions that don't imply code changes
        - Acknowledgements or thank-yous
        - Administrative comments (e.g. "I'll review this later")

        Comment:
        #{@body}

        Respond with ONLY compact JSON in this exact shape:
        {"actionable":true,"reason":"one sentence"}

        Set actionable to true only if the comment clearly requests or implies code changes.
      PROMPT
    end
  end
end
